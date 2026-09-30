import SwiftUI
import AppKit
import Quartz
import GoelCore

enum SFTPFileIcon {
    enum Category { case image, video, audio, archive, code, pdf, text, disk, app, other }

    static func category(of name: String) -> Category {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic", "svg", "ico": return .image
        case "mp4", "mkv", "mov", "avi", "wmv", "flv", "webm", "m4v", "mpg", "mpeg": return .video
        case "mp3", "wav", "flac", "aac", "ogg", "m4a", "wma", "aiff": return .audio
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "zst": return .archive
        case "swift", "c", "h", "cpp", "cc", "py", "js", "ts", "go", "rs", "rb", "java",
             "kt", "sh", "json", "yml", "yaml", "xml", "html", "css", "toml", "php", "sql": return .code
        case "pdf": return .pdf
        case "txt", "md", "log", "rtf", "csv", "conf", "ini", "env": return .text
        case "iso", "img", "dmg", "vmdk", "qcow2": return .disk
        case "app", "deb", "rpm", "pkg", "exe", "apk", "appimage": return .app
        default: return .other
        }
    }

    static func symbol(for entry: SFTPEntry) -> String {
        guard !entry.isDirectory else { return "folder.fill" }
        switch category(of: entry.name) {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .archive: return "doc.zipper"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .disk: return "opticaldiscdrive"
        case .app: return "app.badge"
        case .other: return "doc"
        }
    }

    static func tint(for entry: SFTPEntry) -> Color {
        guard !entry.isDirectory else { return Theme.accent }
        switch category(of: entry.name) {
        case .image: return Theme.indigo
        case .video, .pdf: return Theme.red
        case .audio, .archive: return Theme.orange
        case .code, .app: return Theme.green
        case .disk: return Theme.indigo
        case .text, .other: return .secondary
        }
    }
}

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
