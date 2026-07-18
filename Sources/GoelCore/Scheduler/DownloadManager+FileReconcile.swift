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

    /// Seconds between filesystem-reconciliation sweeps. Cheap `stat`-level
    /// existence checks, so a short interval is fine; the sweep only publishes
    /// when something actually changed.
    static let fileReconcileInterval: UInt64 = 5

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
    public func reconcileCompletedFiles() {
        guard pruneMissingCompletedFiles() else { return }
        publish()
        schedule()
    }

    /// Remove every completed task whose payload no longer exists. Returns whether
    /// anything was pruned so callers can decide to publish. Does not itself
    /// publish — keeping the mutation and the notification separable.
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
        guard fm.fileExists(atPath: task.saveDirectory) else { return false }
        return !fm.fileExists(atPath: task.savePath)
    }

    /// Tear a task out of the in-memory queue and the on-disk store without
    /// touching the filesystem (the payload is already gone). Mirrors the local
    /// bookkeeping of ``remove(_:deleteData:)`` minus the engine call — a
    /// completed task holds no live engine state.
    private func dropTaskLocally(_ id: DownloadTask.ID) {
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = nil
        consumers[id]?.cancel()
        consumers[id] = nil
        runningSlots.remove(id)
        engineStarted.remove(id)
        statsMarks[id] = nil
        speedMeters[id] = nil
        if let i = index(of: id) { tasks.remove(at: i) }
        persistRemoval(id)
    }
}
