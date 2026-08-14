import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    func isSelected(_ id: DownloadTask.ID) -> Bool { selection.contains(id) }

    /// The selected rows in list order — what every command acting on "the selection" runs over.
    var selectedTasks: [DownloadTask] {
        visibleTasks.filter { selection.contains($0.id) }
    }

    func selectOnly(_ id: DownloadTask.ID) {
        selection = [id]
        primarySelection = id
        selectionAnchor = id
    }

    func toggleSelection(_ id: DownloadTask.ID) {
        if selection.contains(id) {
            selection.remove(id)
            if primarySelection == id { primarySelection = selection.first }
        } else {
            selection.insert(id)
            primarySelection = id
        }
        // A ⌘-click re-anchors even when it deselects, so the next ⇧-click extends from the row
        // the user last touched — the same rule Finder and Mail follow.
        selectionAnchor = id
    }

    /// ⇧-click and ⇧-arrow: select the run between the anchor and `id`. `additive` (⇧⌘-click)
    /// keeps whatever was already selected instead of replacing it.
    func extendSelection(through id: DownloadTask.ID, additive: Bool = false) {
        let anchor = selectionAnchor ?? primarySelection
        let run = SelectionRange.ids(in: visibleTasks, from: anchor, through: id)
        guard !run.isEmpty else { return }
        selection = additive ? selection.union(run) : Set(run)
        // The anchor deliberately stays put: shift-clicking again has to be able to shrink the
        // run back down, not just grow it from wherever the last one ended.
        selectionAnchor = anchor ?? id
        primarySelection = id
    }

    func selectAll() {
        let ids = visibleTasks.map(\.id)
        selection = Set(ids)
        // Keep the focused row where it was so the detail panel doesn't jump to row one.
        if let primary = primarySelection, selection.contains(primary) {
            selectionAnchor = primary
        } else {
            primarySelection = ids.first
            selectionAnchor = ids.first
        }
    }

    func selectCompleted() {
        let completed = visibleTasks.filter { $0.status == .completed }
        selection = Set(completed.map(\.id))
        primarySelection = completed.first?.id
        selectionAnchor = completed.first?.id
    }

    func selectNone() {
        selection = []
        primarySelection = nil
        selectionAnchor = nil
    }

    /// Arrow-key movement. Plain moves the selection, `extending` (⇧) grows the run from the anchor.
    @discardableResult
    func moveSelection(by offset: Int, extending: Bool) -> Bool {
        guard let next = SelectionRange.neighbor(in: visibleTasks,
                                                 from: primarySelection,
                                                 offset: offset) else { return false }
        if extending { extendSelection(through: next) } else { selectOnly(next) }
        return true
    }

    /// Home/End: jump to the first or last visible row, extending from the anchor with ⇧.
    @discardableResult
    func selectEdge(last: Bool, extending: Bool) -> Bool {
        guard let edge = last ? visibleTasks.last?.id : visibleTasks.first?.id else { return false }
        if extending { extendSelection(through: edge) } else { selectOnly(edge) }
        return true
    }

    // MARK: - Commands over the whole selection

    /// True when a row command should run over every selected row instead of just the row that
    /// was clicked — the rule every macOS list follows for a right-click inside a multi-selection.
    func actsOnSelection(_ id: DownloadTask.ID) -> Bool {
        selection.contains(id) && selectedTasks.count > 1
    }

    func pauseSelected() {
        for task in selectedTasks where task.status.isActive { pause(task.id) }
    }

    func resumeSelected() {
        for task in selectedTasks where task.status == .paused || task.status == .queued {
            resume(task.id)
        }
    }

    func retrySelected() {
        for task in selectedTasks {
            if case .failed = task.status { retry(task.id) }
        }
    }

    func visibleNeighbor(after id: DownloadTask.ID) -> DownloadTask.ID? {
        guard let idx = visibleTasks.firstIndex(where: { $0.id == id }) else {
            return visibleTasks.first(where: { $0.id != id })?.id
        }
        if idx + 1 < visibleTasks.count { return visibleTasks[idx + 1].id }
        if idx - 1 >= 0 { return visibleTasks[idx - 1].id }
        return nil
    }
}
