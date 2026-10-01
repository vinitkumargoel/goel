import AppKit
import Foundation
import GoelCore

/// What the Dock icon's menu lists: up to three running downloads with their progress.
enum DockMenuModel {

    static let activeLimit = 3

    struct Row: Equatable, Sendable {
        let id: UUID
        let title: String
    }

    static func activeRows(_ tasks: [DownloadTask], limit: Int = activeLimit) -> [Row] {
        tasks.filter { $0.status == .downloading }
            .prefix(limit)
            .map { task in
                let percent = Int((task.fractionCompleted * 100).rounded(.down))
                let shown = task.totalBytes == nil ? task.name : L10n.t("%1$@ — %2$d%%", task.name, percent)
                return Row(id: task.id, title: shown)
            }
    }

    static func hasPausable(_ tasks: [DownloadTask]) -> Bool {
        tasks.contains { $0.status.isActiveWork }
    }

    static func hasResumable(_ tasks: [DownloadTask]) -> Bool {
        tasks.contains { $0.status == .paused }
    }
}

/// What the menu shows, read on the main actor and handed to AppKit's (nonisolated) delegate call.
struct DockMenuSnapshot: Sendable, Equatable {
    var rows: [DockMenuModel.Row]
    var canPause: Bool
    var canResume: Bool

    init(tasks: [DownloadTask]) {
        rows = DockMenuModel.activeRows(tasks)
        canPause = DockMenuModel.hasPausable(tasks)
        canResume = DockMenuModel.hasResumable(tasks)
    }
}

/// Builds the menu fresh each time AppKit asks, so it never shows stale progress. AppKit calls
/// the delegate, and the menu's actions, on the main thread.
final class DockMenuBuilder: NSObject, @unchecked Sendable {
    static let shared = DockMenuBuilder()

    func menu(for snapshot: DockMenuSnapshot) -> NSMenu {
        let menu = NSMenu()
        for row in snapshot.rows {
            let item = NSMenuItem(title: row.title, action: #selector(showTask(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            menu.addItem(item)
        }
        if !snapshot.rows.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item(L10n.t("Pause All"), #selector(pauseAll), enabled: snapshot.canPause))
        menu.addItem(item(L10n.t("Resume All"), #selector(resumeAll), enabled: snapshot.canResume))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("Add from Clipboard"), #selector(addFromClipboard), enabled: true))
        return menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func showTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        MainActor.assumeIsolated {
            MainWindowPresenter.activate()
            AppViewModel.shared?.reveal(id)
        }
    }

    @objc private func pauseAll() { MainActor.assumeIsolated { AppViewModel.shared?.pauseAll() } }
    @objc private func resumeAll() { MainActor.assumeIsolated { AppViewModel.shared?.resumeAll() } }
    @objc private func addFromClipboard() { MainActor.assumeIsolated { AppViewModel.shared?.addFromClipboard() } }
}
