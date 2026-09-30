import Foundation

extension DownloadManager {

    /// Reorders the queue. Every row is renumbered densely, but only rows whose number actually
    /// changed are written, in one transaction. Nothing running is stopped: the new order decides
    /// which queued row takes the next free slot.
    public func moveInQueue(_ ids: [DownloadTask.ID], to placement: QueueOrder.Placement) {
        let reordered = QueueOrder.moving(ids, to: placement, in: tasks)
        let changed = zip(tasks, reordered).compactMap { $0.queuePosition == $1.queuePosition ? nil : $1 }
        guard !changed.isEmpty else { return }
        // Same array order, so `taskIndex` and `dedupIndex` stay valid.
        tasks = reordered
        // Full rows carry the latest resume data, so they settle any coalesced flush, as `persist` does.
        for task in changed { resumeDirty.remove(task.id) }
        pipeline?.enqueue(.saveTasks(changed))
        publish()
    }
}
