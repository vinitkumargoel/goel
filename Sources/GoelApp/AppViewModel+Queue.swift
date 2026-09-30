import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    static let groupingKey = "downloadList.grouping"

    static var storedGrouping: ListGrouping {
        UserDefaults.standard.string(forKey: groupingKey).flatMap(ListGrouping.init(rawValue:)) ?? .none
    }

    /// Dragging rows only means something when the list is drawn in queue order: under any other
    /// sort, or split into groups, "drop above this row" has no single queue position.
    var isQueueReorderable: Bool { sortKey == .index && grouping == .none }

    func moveInQueue(_ ids: [DownloadTask.ID], to placement: QueueOrder.Placement) {
        guard !ids.isEmpty else { return }
        let manager = self.manager
        Task { await manager.moveInQueue(ids, to: placement) }
    }

    /// The context menu's targets: the whole selection when the clicked row is part of it.
    func queueTargets(for id: DownloadTask.ID) -> [DownloadTask.ID] {
        selection.contains(id) && selection.count > 1 ? selectedTasks.map(\.id) : [id]
    }

    /// Drops the dragged rows next to `anchor`. `above` is on screen; a descending "#" sort draws
    /// the queue upside down, so there "above" is later in the queue.
    func dropQueueDrag(onto anchor: DownloadTask.ID, above: Bool) {
        let ids = queueDragIDs.filter { $0 != anchor }
        queueDragIDs = []
        guard !ids.isEmpty else { return }
        let before = above == sortAscending
        moveInQueue(ids, to: before ? .before(anchor) : .after(anchor))
    }

    /// What a drag started on `id` carries: the selection if the row is in it, else the row alone.
    func beginQueueDrag(from id: DownloadTask.ID) -> [DownloadTask.ID] {
        let ids = queueTargets(for: id)
        queueDragIDs = ids
        return ids
    }

    /// Takes every finished row off the list. Files stay on disk, like Remove from List, and the
    /// same Undo toast brings the rows back.
    func clearCompleted() {
        let done = tasks.filter { $0.status == .completed }.map(\.id)
        guard !done.isEmpty else { toastWarning(L10n.t("No completed downloads to clear")); return }
        removeFromList(done)
    }
}
