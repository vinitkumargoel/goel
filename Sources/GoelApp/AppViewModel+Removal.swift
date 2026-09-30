import Foundation
import GoelCore

/// "Remove from List" with Undo. The manager has no re-insert API, so the removal is held back
/// instead: the rows leave the list at once, and only when the Undo window closes (or the app
/// quits) are they removed from the queue. Undo therefore restores them exactly — same id,
/// resume data, status and cookies — without a round trip through import.
struct PendingRemoval {
    /// The undo stack keys its entries on a target object; one per batch lets a commit retract
    /// exactly its own entry.
    final class Token {}

    let token = Token()
    let tasks: [DownloadTask]
    /// Running or waiting rows are paused for the window and started again on Undo.
    let resumeOnUndo: [DownloadTask.ID]

    var ids: Set<DownloadTask.ID> { Set(tasks.map(\.id)) }
    var dedupKeys: Set<String> { Set(tasks.map(\.source.dedupKey)) }
}

@MainActor
extension AppViewModel {

    /// Matches the Undo toast's dwell, so the button never outlives what it can undo.
    static let removalUndoWindow: TimeInterval = 8

    func removeFromList(_ ids: [DownloadTask.ID]) {
        let wanted = Set(ids)
        let targets = tasks.filter { wanted.contains($0.id) }
        guard !targets.isEmpty else { return }
        // Must run BEFORE the rows disappear, or selection lands on the raw-first row.
        let nextPrimary = targets.count == 1
            ? visibleNeighbor(after: targets[0].id)
            : visibleTasks.first { !wanted.contains($0.id) }?.id
        selection.subtract(wanted)
        if let primary = primarySelection, wanted.contains(primary) { primarySelection = nextPrimary }
        if let anchor = selectionAnchor, wanted.contains(anchor) { selectionAnchor = nextPrimary }

        let moving = targets.filter { $0.status.isActive || $0.status == .queued }.map(\.id)
        let batch = UUID()
        let removal = PendingRemoval(tasks: targets, resumeOnUndo: moving)
        pendingRemovals[batch] = removal
        pendingRemovalIDs.formUnion(removal.ids)
        tasks.removeAll { wanted.contains($0.id) }
        recomputeVisible()
        // A removed download must not keep transferring, invisibly, for the length of the window.
        let manager = self.manager
        Task { for id in moving { await manager.pause(id) } }

        undoManager?.registerUndo(withTarget: removal.token) { [weak self] _ in
            MainActor.assumeIsolated { self?.undoRemoval(batch) }
        }
        undoManager?.setActionName(L10n.t("Remove from List"))

        let message = targets.count == 1
            ? L10n.t("Removed “%@” from the list", targets[0].name)
            : L10n.t("Removed %d downloads from the list", targets.count)
        toastNow(message, action: Toast.Action(title: L10n.t("Undo")) { [weak self] in
            self?.undoRemoval(batch)
        })
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.removalUndoWindow * 1_000_000_000))
            await self?.commitRemoval(batch)
        }
    }

    func undoRemoval(_ batch: UUID) {
        guard let removal = pendingRemovals.removeValue(forKey: batch) else { return }
        undoManager?.removeAllActions(withTarget: removal.token)
        pendingRemovalIDs.subtract(removal.ids)
        let restoredIDs = removal.ids
        Task { [weak self] in
            guard let self else { return }
            for id in removal.resumeOnUndo { await self.manager.resume(id) }
            // The latest state of each row, not the copy taken at removal time.
            var restored: [DownloadTask] = []
            for id in restoredIDs {
                if let task = await self.manager.task(id) { restored.append(task) }
            }
            self.tasks.removeAll { restoredIDs.contains($0.id) }
            self.tasks.append(contentsOf: restored)
            self.recomputeVisible()
        }
        toastNow(removal.tasks.count == 1
                 ? L10n.t("Restored “%@”", removal.tasks[0].name)
                 : L10n.t("Restored %d downloads", removal.tasks.count))
    }

    func commitRemoval(_ batch: UUID) async {
        guard let removal = pendingRemovals.removeValue(forKey: batch) else { return }
        undoManager?.removeAllActions(withTarget: removal.token)
        for task in removal.tasks { await manager.remove(task.id, deleteData: false) }
        pendingRemovalIDs.subtract(removal.ids)
    }

    /// Before adding a source again: a row still in its Undo window would swallow the add.
    func commitPendingRemovals(matching dedupKeys: Set<String>) async {
        let batches = pendingRemovals.filter { !$0.value.dedupKeys.isDisjoint(with: dedupKeys) }.map(\.key)
        for batch in batches { await commitRemoval(batch) }
    }

    func commitAllPendingRemovals() async {
        for batch in Array(pendingRemovals.keys) { await commitRemoval(batch) }
    }
}
