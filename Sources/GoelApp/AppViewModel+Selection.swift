import Foundation
import AppKit
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

    func selectFailed() {
        let failed = visibleTasks.filter { $0.status.isFailed }
        selection = Set(failed.map(\.id))
        primarySelection = failed.first?.id
        selectionAnchor = failed.first?.id
    }

    /// Brings one download into view and selects it: from the menu bar, a toast's Show, or the
    /// command palette. Only widens the list when the current filter or search hides the row.
    func reveal(_ id: DownloadTask.ID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        closeServerBrowser()
        if !visibleTasks.contains(where: { $0.id == id }) {
            search = ""
            filter = .all
        }
        selectOnly(id)
    }

    /// Shows the list under one filter with nothing hidden by search, e.g. "4 more" in the menu bar.
    func showFilter(_ newFilter: SidebarFilter) {
        closeServerBrowser()
        search = ""
        filters = DownloadFilters().setting(newFilter)
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

    /// ⌘⌫ in the list, or the menu item: the same confirmation the context menu shows, never a silent delete.
    func confirmMoveSelectionToTrash() {
        let targets = selectedTasks
        guard let first = targets.first else { return }
        let single = targets.count == 1
        requestConfirm(
            title: single ? L10n.t("Move “%@” to the Trash?", first.name)
                          : L10n.t("Move the files of %d downloads to the Trash?", targets.count),
            message: single ? L10n.t("It is removed from the list. You can restore the file from the Trash.")
                            : L10n.t("They are removed from the list. You can restore the files from the Trash."),
            confirmTitle: L10n.t("Move to Trash"),
            destructive: true
        ) { [weak self] in self?.removeSelected(deleteData: true) }
    }

    /// The palette's "Retry All Failed": one command instead of hunting failures down by filter.
    func retryAllFailed() {
        let failed = tasks.filter { $0.status.isFailed }
        guard !failed.isEmpty else { toastWarning(L10n.t("No failed downloads")); return }
        for task in failed { retry(task.id) }
        toastSuccess(failed.count == 1 ? L10n.t("Retrying 1 download")
                                       : L10n.t("Retrying %d downloads", failed.count))
    }

    func retrySelected() {
        for task in selectedTasks {
            if task.status.isFailed { retry(task.id) }
        }
    }

    /// In queue order, so the selection keeps its relative order on the move.
    func moveSelectedInQueue(to placement: QueueOrder.Placement) {
        let ids = selectedTasks.map(\.id).sorted { (queueRanks[$0] ?? .max) < (queueRanks[$1] ?? .max) }
        guard !ids.isEmpty else { return }
        moveInQueue(ids, to: placement)
    }

    func setPrioritySelected(_ priority: FilePriority) {
        let ids = selectedTasks.map(\.id)
        guard !ids.isEmpty else { return }
        let manager = self.manager
        Task { for id in ids { await manager.setPriority(priority, task: id) } }
        toastSuccess(ids.count == 1 ? L10n.t("Priority set to %@", priority.title)
                                    : L10n.t("Priority set to %1$@ for %2$d downloads", priority.title, ids.count))
    }

    /// One Finder window selecting every file that exists, rather than one per row.
    func revealSelected() {
        let urls = selectedTasks
            .map { URL(fileURLWithPath: $0.savePath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { toastWarning(L10n.t("None of the selected files are on disk")); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectedLinks() {
        let links = selectedTasks.map(\.sourceLocator)
        guard !links.isEmpty else { return }
        copyToPasteboard(links.joined(separator: "\n"))
        toastSuccess(links.count == 1 ? L10n.t("Link copied") : L10n.t("%d links copied", links.count))
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
