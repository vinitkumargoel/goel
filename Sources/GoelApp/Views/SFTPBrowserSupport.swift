import SwiftUI
import AppKit
import Quartz
import GoelCore

// MARK: - File-type icons

/// An SF Symbol + tint for a remote entry, chosen by extension so a listing is
/// scannable at a glance (instead of one generic doc icon for every file).
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

// MARK: - Quick Look

/// Presents a downloaded temp file in the system Quick Look panel. A single
/// shared presenter drives `QLPreviewPanel` directly (set as its data source and
/// made key), so Space / "Quick Look" peeks a remote file after it's fetched.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var url: URL?

    func present(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
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
}
