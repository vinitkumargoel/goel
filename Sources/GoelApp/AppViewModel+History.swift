import Foundation
import GoelCore

extension AppViewModel {
    /// "Remove from History" for one or many entries: one write, one toast, one Undo (the toast's
    /// button or Edit ▸ Undo in the window that owns `undoManager`).
    func removeHistoryEntries(_ entries: [HistoryEntry], undoManager: UndoManager? = nil) {
        guard !entries.isEmpty else { return }
        let manager = self.manager
        let ids = Set(entries.map(\.id))
        Task { [weak self] in
            await manager.removeHistoryEntries(ids)
            self?.bumpHistoryRevision(after: 0.3)
        }
        let undone = UndoOnce()
        let restore: @MainActor () -> Void = { [weak self] in
            guard undone.claim() else { return }
            Task { [weak self] in
                await manager.restoreHistoryEntries(entries)
                self?.bumpHistoryRevision(after: 0.3)
            }
        }
        undoManager?.registerUndo(withTarget: undone) { _ in MainActor.assumeIsolated { restore() } }
        undoManager?.setActionName(L10n.t("Remove from History"))
        let message = entries.count == 1 ? L10n.t("Entry removed") : L10n.t("%d entries removed", entries.count)
        toastSuccess(message, action: Toast.Action(title: L10n.t("Undo")) {
            undoManager?.removeAllActions(withTarget: undone)
            restore()
        })
    }
}

/// Lets the toast button and Edit ▸ Undo race safely: whichever comes first restores, once.
final class UndoOnce {
    private var used = false
    func claim() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}
