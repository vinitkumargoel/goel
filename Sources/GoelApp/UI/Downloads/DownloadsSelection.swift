import Foundation
import GoelCore

/// Selection in the order a layout draws its items. The list draws `visibleTasks` as is, so it
/// keeps the view model's own methods; the board reads lane by lane, so ranges and arrow keys
/// walk the board's order there. Both read `boardLanes`, the same lanes the board draws (rebuilt
/// with `visibleTasks`), so a card that just changed lanes is where the user sees it.
@MainActor
extension AppViewModel {

    func orderedTasks(for layout: DownloadsLayout) -> [DownloadTask] {
        layout == .board ? BoardLanes.flattened(boardLanes) : visibleTasks
    }

    /// ⇧-click: the run from the anchor to `id` in the layout's order; `additive` (⇧⌘) keeps
    /// what was already selected.
    func extendSelection(through id: DownloadTask.ID, additive: Bool, in layout: DownloadsLayout) {
        guard layout == .board else { extendSelection(through: id, additive: additive); return }
        let anchor = selectionAnchor ?? primarySelection
        let run = SelectionRange.ids(in: orderedTasks(for: layout), from: anchor, through: id)
        guard !run.isEmpty else { return }
        selection = additive ? selection.union(run) : Set(run)
        selectionAnchor = anchor ?? id
        primarySelection = id
    }

    /// ↑ / ↓, with ⇧ to extend.
    @discardableResult
    func moveSelection(by offset: Int, extending: Bool, in layout: DownloadsLayout) -> Bool {
        guard layout == .board else { return moveSelection(by: offset, extending: extending) }
        guard let next = SelectionRange.neighbor(in: orderedTasks(for: layout), from: primarySelection,
                                                 offset: offset) else { return false }
        if extending { extendSelection(through: next, additive: false, in: layout) } else { selectOnly(next) }
        return true
    }

    /// Home / End.
    @discardableResult
    func selectEdge(last: Bool, extending: Bool, in layout: DownloadsLayout) -> Bool {
        guard layout == .board else { return selectEdge(last: last, extending: extending) }
        let ordered = orderedTasks(for: layout)
        guard let edge = last ? ordered.last?.id : ordered.first?.id else { return false }
        if extending { extendSelection(through: edge, additive: false, in: layout) } else { selectOnly(edge) }
        return true
    }

    /// ← / → on the board: across lanes.
    @discardableResult
    func moveSelectionAcrossLanes(by step: Int, extending: Bool) -> Bool {
        guard let next = BoardLanes.laneNeighbor(in: boardLanes, from: primarySelection, step: step) else {
            return false
        }
        if extending { extendSelection(through: next, additive: false, in: .board) } else { selectOnly(next) }
        return true
    }

    /// Double-click and Return: a finished file opens, anything else shows its folder.
    func openOrReveal(_ task: DownloadTask) {
        if task.status == .completed { openFile(task) } else { revealInFinder(task) }
    }
}
