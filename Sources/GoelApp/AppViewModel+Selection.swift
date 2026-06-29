import Foundation
import GoelCore

// MARK: - Multi-selection

/// Row selection: the highlighted set plus the "primary" row whose details the
/// detail panel shows. Split out of `AppViewModel.swift` so the bridge proper
/// stays focused on the manager round-trips.
@MainActor
extension AppViewModel {

    func isSelected(_ id: DownloadTask.ID) -> Bool { selection.contains(id) }

    /// Replace the selection with a single row (a plain click).
    func selectOnly(_ id: DownloadTask.ID) {
        selection = [id]
        primarySelection = id
    }

    /// Add or remove a row from the selection (a ⌘-click), keeping the primary
    /// pointed at a still-selected row.
    func toggleSelection(_ id: DownloadTask.ID) {
        if selection.contains(id) {
            selection.remove(id)
            if primarySelection == id { primarySelection = selection.first }
        } else {
            selection.insert(id)
            primarySelection = id
        }
    }

    /// Select every currently visible row; the primary becomes the first of them.
    func selectAll() {
        selection = Set(visibleTasks.map(\.id))
        primarySelection = visibleTasks.first?.id
    }

    /// Select every completed row in the visible list; the primary becomes the first.
    func selectCompleted() {
        let completed = visibleTasks.filter { $0.status == .completed }
        selection = Set(completed.map(\.id))
        primarySelection = completed.first?.id
    }

    /// Clear the selection so the detail panel shows its empty state.
    func selectNone() {
        selection = []
        primarySelection = nil
    }

    /// The visible row that should take over the primary selection when `id` is
    /// removed: the next row down, or the previous one if `id` was last, or `nil`
    /// if the visible list becomes empty.
    func visibleNeighbor(after id: DownloadTask.ID) -> DownloadTask.ID? {
        guard let idx = visibleTasks.firstIndex(where: { $0.id == id }) else {
            return visibleTasks.first(where: { $0.id != id })?.id
        }
        if idx + 1 < visibleTasks.count { return visibleTasks[idx + 1].id }
        if idx - 1 >= 0 { return visibleTasks[idx - 1].id }
        return nil
    }
}
