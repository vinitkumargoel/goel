import Foundation

// MARK: - Reconcile completed downloads with the filesystem

/// Keeps the download list honest about the files it claims exist: when the user
/// deletes or moves a finished download's payload in Finder, the row is removed.
///
/// Only `.completed` tasks are ever pruned — an in-flight, queued, paused or
/// failed task legitimately has a missing or partial file on disk. And even for a
/// completed task the check is deliberately conservative (see
/// ``completedPayloadIsMissing(_:fileManager:)``): the payload counts as deleted
/// only when its *containing directory still exists* but the file/folder inside
/// it is gone. An unmounted volume or a moved-away download folder makes both
/// absent, which is ambiguous — so the row is kept rather than lost.
extension DownloadManager {

    /// Seconds between filesystem-reconciliation sweeps. The `stat` calls run off
    /// the actor (see ``reconcileCompletedFiles()``) so a short interval is fine;
    /// the sweep only publishes when something actually changed.
    static let fileReconcileInterval: UInt64 = 5

    /// One completed task's identity plus the two paths a sweep needs to `stat`.
    /// Snapshotted on the actor so the probing itself can happen off it.
    private struct PayloadProbe: Sendable {
        let id: DownloadTask.ID
        let saveDirectory: String
        let savePath: String
    }

    /// (Re)start the periodic sweep. Idempotent — cancels any prior loop first.
    func startFileReconcile() {
        fileReconcileTask?.cancel()
        fileReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.fileReconcileInterval * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.reconcileCompletedFiles()
            }
        }
    }

    /// Prune completed downloads whose payload is gone, publishing if anything
    /// changed. Also invoked on demand (e.g. when the app is reactivated after
    /// the user deleted a file in Finder) so the list updates without waiting for
    /// the next sweep.
    ///
    /// The `stat`ing happens on a detached task, never on this actor. `stat` is
    /// only cheap on a local volume — the app happily saves to SMB/NFS shares and
    /// removable disks, where each probe can cost milliseconds and an unresponsive
    /// (but still mounted) share can block for the mount timeout. Since this actor
    /// is the single serialization point for every engine event, blocking here
    /// stalls progress folding, slot release and queued-task promotion for the
    /// whole queue. So: snapshot on the actor, probe off it, apply back on it.
    ///
    /// Because the queue can move while the probe is in flight, each result is
    /// re-verified against the live task before the row is dropped.
    public func reconcileCompletedFiles() async {
        let probes = tasks.compactMap { task -> PayloadProbe? in
            guard task.status == .completed else { return nil }
            return PayloadProbe(id: task.id,
                                saveDirectory: task.saveDirectory,
                                savePath: task.savePath)
        }
        guard !probes.isEmpty else { return }

        // A private `FileManager` rather than `.default`, so the off-actor probing
        // shares no instance state with callers on other threads.
        let missing = await Task.detached(priority: .utility) {
            let fm = FileManager()
            return probes.filter {
                Self.payloadIsMissing(saveDirectory: $0.saveDirectory, savePath: $0.savePath, fileManager: fm)
            }
        }.value

        guard pruneConfirmedMissing(missing) else { return }
        publish()
        schedule()
    }

    /// Drop the rows a completed probe found missing, skipping any whose task has
    /// since been removed, restarted, or re-targeted at a different path — the
    /// probe result is a snapshot and must not overrule newer state. Returns
    /// whether anything was pruned.
    private func pruneConfirmedMissing(_ probes: [PayloadProbe]) -> Bool {
        var pruned = false
        for probe in probes {
            guard let i = index(of: probe.id) else { continue }
            let task = tasks[i]
            guard task.status == .completed, task.savePath == probe.savePath else { continue }
            dropTaskLocally(probe.id)
            pruned = true
        }
        return pruned
    }

    /// Remove every completed task whose payload no longer exists. Returns whether
    /// anything was pruned so callers can decide to publish. Does not itself
    /// publish — keeping the mutation and the notification separable.
    ///
    /// Synchronous, and therefore blocking: reserved for `restore()`, which runs
    /// once at launch before any transfer is live, so there is no queue to stall
    /// and the rows must be settled before the list is first shown. The periodic
    /// sweep uses ``reconcileCompletedFiles()`` instead, which probes off-actor.
    @discardableResult
    func pruneMissingCompletedFiles() -> Bool {
        let fm = FileManager.default
        let gone = tasks.filter {
            $0.status == .completed && Self.completedPayloadIsMissing($0, fileManager: fm)
        }
        guard !gone.isEmpty else { return false }
        for task in gone { dropTaskLocally(task.id) }
        return true
    }

    /// Whether a completed task's payload has been deleted/moved out from under
    /// us. Conservative on purpose: an absent *containing directory* is treated
    /// as "unknown" (unmounted volume, moved download folder), not "deleted".
    static func completedPayloadIsMissing(_ task: DownloadTask, fileManager fm: FileManager) -> Bool {
        payloadIsMissing(saveDirectory: task.saveDirectory, savePath: task.savePath, fileManager: fm)
    }

    /// The same rule expressed over bare paths, so the off-actor sweep can apply
    /// it to a ``PayloadProbe`` snapshot without carrying a whole `DownloadTask`.
    static func payloadIsMissing(saveDirectory: String, savePath: String, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: saveDirectory) else { return false }
        return !fm.fileExists(atPath: savePath)
    }

    /// Tear a task out of the in-memory queue and the on-disk store without
    /// touching the filesystem (the payload is already gone). Mirrors the local
    /// bookkeeping of ``remove(_:deleteData:)`` minus the engine call — a
    /// completed task holds no live engine state.
    private func dropTaskLocally(_ id: DownloadTask.ID) {
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
    }
}
