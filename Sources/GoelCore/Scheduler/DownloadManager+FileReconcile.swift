import Foundation

// MARK: - Reconcile completed downloads with the filesystem

/// Removes rows whose finished payload the user deleted/moved in Finder. Only `.completed` tasks, and only
/// when the *containing directory still exists* — an unmounted volume is ambiguous, so the row is kept.
extension DownloadManager {

    /// Seconds between filesystem-reconciliation sweeps. The `stat` calls run off the actor
    /// (``reconcileCompletedFiles()``) so a short interval is fine; it publishes only on a change.
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

    /// Prune completed downloads whose payload is gone. Snapshot on the actor, `stat` off it, apply back:
    /// a `stat` on an unresponsive SMB/NFS share would otherwise stall every engine event. Results rechecked.
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

    /// Drop rows a probe found missing, skipping any task since removed, restarted or re-targeted — the
    /// probe is a snapshot and must not overrule newer state. Returns whether anything was pruned.
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

    /// Remove completed tasks whose payload is gone; returns whether anything was pruned, never publishes.
    /// Blocking, so reserved for `restore()` at launch; the sweep uses ``reconcileCompletedFiles()``.
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

    /// Whether a completed task's payload was deleted/moved out from under us. Conservative: an absent
    /// *containing directory* means "unknown" (unmounted volume, moved folder), not "deleted".
    static func completedPayloadIsMissing(_ task: DownloadTask, fileManager fm: FileManager) -> Bool {
        payloadIsMissing(saveDirectory: task.saveDirectory, savePath: task.savePath, fileManager: fm)
    }

    /// The same rule expressed over bare paths, so the off-actor sweep can apply
    /// it to a ``PayloadProbe`` snapshot without carrying a whole `DownloadTask`.
    static func payloadIsMissing(saveDirectory: String, savePath: String, fileManager fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: saveDirectory) else { return false }
        return !fm.fileExists(atPath: savePath)
    }

    /// Tear a task out of the queue and store without touching the filesystem (the payload is already
    /// gone). ``remove(_:deleteData:)``'s bookkeeping minus the engine call — a completed task has none.
    private func dropTaskLocally(_ id: DownloadTask.ID) {
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
    }
}
