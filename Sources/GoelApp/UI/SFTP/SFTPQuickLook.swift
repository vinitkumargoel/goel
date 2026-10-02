import SwiftUI
import AppKit
import Quartz
import GoelCore

/// Presents one file in the shared Quick Look panel. For remote previews it also owns the
/// temporary folder the file was copied into, and deletes it when the preview is replaced or the
/// panel closes — previews are up to 512 MB each and used to pile up in $TMPDIR forever.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    static let tempPrefix = "GoelQL-"

    private var url: URL?
    private var ownedDirectory: URL?
    private var closeObserver: NSObjectProtocol?

    /// - Parameter ownedDirectory: a temp folder holding `url` that the presenter deletes once the
    ///   preview is gone. Pass nil for a file the user owns.
    func present(_ url: URL, ownedDirectory: URL? = nil) {
        if let previous = self.ownedDirectory, previous != ownedDirectory {
            Self.remove(previous)
        }
        self.url = url
        self.ownedDirectory = ownedDirectory
        guard let panel = QLPreviewPanel.shared() else {
            releaseOwnedDirectory()
            return
        }
        panel.dataSource = self
        observeClose(of: panel)
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }

    private func observeClose(of panel: QLPreviewPanel) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.releaseOwnedDirectory()
        }
    }

    private func releaseOwnedDirectory() {
        guard let dir = ownedDirectory else { return }
        ownedDirectory = nil
        url = nil
        Self.remove(dir)
    }

    private static func remove(_ dir: URL) {
        // Only ever delete our own temp folders, whatever a caller passed in.
        guard dir.lastPathComponent.hasPrefix(tempPrefix) else { return }
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: dir) }
    }

    /// Deletes previews left behind by a crash or force-quit. The one-hour cutoff spares a
    /// preview another running instance is still showing.
    static func sweepStaleTemps(olderThan age: TimeInterval = 3600) {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-age)
            for url in items where url.lastPathComponent.hasPrefix(tempPrefix) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: url) }
            }
        }
    }
}
