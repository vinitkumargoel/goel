import Foundation
import GoelCore

/// How a finished removal is worded, and whether it can be undone. Pure, so every wording is testable.
/// Undo re-inserts the rows, never the bytes: it is offered only when no file was unlinked.
struct RemovalReport: Equatable {
    /// nil: say nothing — every file that survived already has the manager's own notice.
    var message: String?
    var offersUndo: Bool
    /// The row comes back, the file does not leave the Trash: the Undo confirmation says so.
    var filesStayInTrash: Bool

    static func make(names: [String], outcomes: [RemovalOutcome], deleteData: Bool) -> RemovalReport {
        let count = outcomes.count
        guard count > 0 else { return RemovalReport(message: nil, offersUndo: false, filesStayInTrash: false) }
        let single = count == 1 ? names.first : nil
        guard deleteData else {
            return RemovalReport(message: single.map { L10n.t("Removed “%@” from the list", $0) }
                                    ?? L10n.t("Removed %d downloads from the list", count),
                                 offersUndo: true, filesStayInTrash: false)
        }
        let kept = outcomes.filter { if case .keptOnDisk = $0 { return true } else { return false } }.count
        let trashed = outcomes.filter { $0 == .trashed }.count
        let unlinked = outcomes.filter { $0 == .deleted || $0 == .handledByEngine }.count
        if kept == count { return RemovalReport(message: nil, offersUndo: false, filesStayInTrash: false) }
        if let name = single {
            switch outcomes[0] {
            case .trashed:
                return RemovalReport(message: L10n.t("Moved “%@” to the Trash", name),
                                     offersUndo: true, filesStayInTrash: true)
            case .deleted:
                return RemovalReport(message: L10n.t("Deleted “%@”", name), offersUndo: false, filesStayInTrash: false)
            case .handledByEngine:
                return RemovalReport(message: L10n.t("Removed “%@”", name), offersUndo: false, filesStayInTrash: false)
            case .nothingToDelete, .keptOnDisk:
                return RemovalReport(message: L10n.t("Removed “%@” from the list", name),
                                     offersUndo: true, filesStayInTrash: false)
            }
        }
        // A mixed batch is worded by what it did to the whole; files kept on disk have their own notices.
        guard unlinked == 0, kept == 0 else {
            return RemovalReport(message: L10n.t("Removed %d downloads", count - kept),
                                 offersUndo: false, filesStayInTrash: false)
        }
        if trashed > 0 {
            return RemovalReport(message: L10n.t("Moved the files of %d downloads to the Trash", count),
                                 offersUndo: true, filesStayInTrash: true)
        }
        return RemovalReport(message: L10n.t("Removed %d downloads from the list", count),
                             offersUndo: true, filesStayInTrash: false)
    }

    /// What the Undo confirmation says once `restored` rows are back.
    func restoredMessage(names: [String]) -> String {
        guard !names.isEmpty else { return L10n.t("Already in your list") }
        if names.count == 1 {
            return filesStayInTrash
                ? L10n.t("Restored “%@” to the list — its file is still in the Trash", names[0])
                : L10n.t("Restored “%@”", names[0])
        }
        return filesStayInTrash
            ? L10n.t("Restored %d downloads to the list — their files are still in the Trash", names.count)
            : L10n.t("Restored %d downloads", names.count)
    }
}

/// One removal: the undo stack keys its entry on this object, so Undo retracts exactly this batch.
@MainActor
final class RemovalBatch {
    /// The rows as the manager held them just before removal (same id, resume data, cookies).
    var removed: [DownloadTask] = []
    var report: RemovalReport?
    var toastID: Toast.ID?
    var isUndone = false
    /// Undo waits for this: `reinsert` skips an id the manager still lists.
    var work: Task<Void, Never>?
}

@MainActor
extension AppViewModel {

    func removeFromList(_ ids: [DownloadTask.ID]) { removeRows(ids, deleteData: false) }

    func remove(_ id: DownloadTask.ID, deleteData: Bool) { removeRows([id], deleteData: deleteData) }

    func removeSelected(deleteData: Bool) { removeRows(selectedTasks.map(\.id), deleteData: deleteData) }

    /// Removes at once — nothing is held back, so a re-add, the portal and the CLI all see the queue as it
    /// is. Undo puts the snapshotted rows back through ``DownloadManager/reinsert(_:)``.
    func removeRows(_ ids: [DownloadTask.ID], deleteData: Bool) {
        let wanted = Set(ids)
        let targets = tasks.filter { wanted.contains($0.id) }
        guard !targets.isEmpty else { return }
        // Must run BEFORE the snapshot drops the rows, or selection lands on the raw-first row.
        let nextPrimary = targets.count == 1
            ? visibleNeighbor(after: targets[0].id)
            : visibleTasks.first { !wanted.contains($0.id) }?.id
        selection.subtract(wanted)
        if let primary = primarySelection, wanted.contains(primary) { primarySelection = nextPrimary }
        if let anchor = selectionAnchor, wanted.contains(anchor) { selectionAnchor = nextPrimary }

        let batch = RemovalBatch()
        if !deleteData {
            // A list removal can't turn out differently from what it says, so its Undo shows with the removal.
            present(RemovalReport.make(names: targets.map(\.name),
                                       outcomes: targets.map { _ in .nothingToDelete }, deleteData: false),
                    for: batch)
        }
        let manager = self.manager
        batch.work = Task { [weak self] in
            var outcomes: [RemovalOutcome] = []
            for target in targets {
                let latest = await manager.task(target.id) ?? target
                guard let outcome = await manager.removeAndReport(target.id, deleteData: deleteData) else { continue }
                batch.removed.append(latest)
                outcomes.append(outcome)
            }
            guard deleteData, let self else { return }
            // Worded from what happened: a file that stayed put must never read as "Moved to the Trash".
            self.present(RemovalReport.make(names: batch.removed.map(\.name), outcomes: outcomes, deleteData: true),
                         for: batch)
        }
    }

    private func present(_ report: RemovalReport, for batch: RemovalBatch) {
        batch.report = report
        guard let message = report.message else { return }
        guard report.offersUndo else { toastNow(message); return }
        undoManager?.registerUndo(withTarget: batch) { [weak self] batch in
            MainActor.assumeIsolated { self?.undoRemoval(batch) }
        }
        undoManager?.setActionName(report.filesStayInTrash ? L10n.t("Move to Trash") : L10n.t("Remove from List"))
        batch.toastID = toastNow(message, action: Toast.Action(title: L10n.t("Undo")) { [weak self] in
            self?.undoRemoval(batch)
        })
    }

    /// From the toast's button or Edit ▸ Undo; either one retires the other.
    func undoRemoval(_ batch: RemovalBatch) {
        guard !batch.isUndone, let report = batch.report, report.offersUndo else { return }
        batch.isUndone = true
        undoManager?.removeAllActions(withTarget: batch)
        if let toastID = batch.toastID { toasts.dismiss(toastID) }
        let manager = self.manager
        Task { [weak self] in
            await batch.work?.value
            await manager.reinsert(batch.removed)
            var restored: [String] = []
            for task in batch.removed {
                if await manager.task(task.id) != nil { restored.append(task.name) }
            }
            self?.toastNow(report.restoredMessage(names: restored))
        }
    }
}
