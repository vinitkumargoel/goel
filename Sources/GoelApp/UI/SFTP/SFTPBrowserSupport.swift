import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// What Get Info learned about one remote item. Built by `SFTPBrowserModel.info(for:)`.
struct SFTPEntryInfo: Equatable {
    let name: String
    let path: String
    let attributes: SFTPAttributes
    let linkTarget: String?
}

/// Which artwork a remote file gets. Folders take the folder tile; files are sorted by extension
/// into the same families the downloads use, with a few remote-only glyphs (code, disk images).
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

    static func artKind(for entry: SFTPEntry) -> StudioArtKind {
        guard !entry.isDirectory else { return .folder }
        return artKind(forName: entry.name)
    }

    static func artKind(forName name: String) -> StudioArtKind {
        switch category(of: name) {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .archive: return .archive
        case .code, .app: return .app
        case .pdf, .text: return .doc
        case .disk: return .disc
        case .other: return .other
        }
    }

    /// The glyph on the tile: the family's own, except where a remote file reads better with its
    /// own (a script is a terminal, not a package).
    static func symbol(for entry: SFTPEntry) -> String {
        guard !entry.isDirectory else { return "folder" }
        switch category(of: entry.name) {
        case .code: return "terminal"
        case .pdf: return "doc.richtext"
        default: return artKind(for: entry).symbol ?? "doc"
        }
    }

    /// "Folder", "Alias", or the system's name for the type ("Zstandard archive").
    static func kindLabel(for entry: SFTPEntry) -> String {
        if entry.isSymlink { return entry.isDirectory ? L10n.t("Alias to folder") : L10n.t("Alias") }
        if entry.isDirectory { return L10n.t("Folder") }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let description = UTType(filenameExtension: ext)?.localizedDescription,
           !description.isEmpty {
            return description
        }
        let kind = artKind(for: entry)
        return kind == .other ? L10n.t("File") : kind.accessibilityName
    }

    /// The spoken kind, which never uses the system description: "Folder, backups".
    static func spokenKind(for entry: SFTPEntry) -> String {
        if entry.isSymlink { return entry.isDirectory ? L10n.t("Alias to folder") : L10n.t("Alias") }
        return entry.isDirectory ? L10n.t("Folder") : L10n.t("File")
    }
}

// MARK: - Transfer presentation

extension SFTPTransfer {
    /// The Studio colour family for this transfer's state.
    var studioTone: StudioTone {
        switch state {
        case .failed: return .bad
        case .finished: return .good
        case .cancelled, .waiting, .paused: return .neutral
        case .running: return direction == .upload ? .upload : .accent
        }
    }

    /// The tone its progress bar and ring are drawn in.
    var progressTone: StudioProgressTone {
        switch state {
        case .failed: return .bad
        case .finished: return .good
        case .paused, .waiting, .cancelled: return .paused
        case .running: return direction == .upload ? .upload : .accent
        }
    }

    /// Upload teal, download accent: the colour of the bytes' direction, whatever the state.
    var studioDirectionColor: Color {
        direction == .upload ? Studio.Palette.upload : Studio.Palette.accent
    }

    /// The artwork of the thing being moved.
    var artKind: StudioArtKind {
        isDirectory ? .folder : SFTPFileIcon.artKind(forName: name)
    }

    /// "↓ from nas.home", "↑ to seedbox", "⇄ on nas.home".
    func routeLine(server: String) -> String {
        switch direction {
        case .download: return L10n.t("↓ from %@", server)
        case .upload: return L10n.t("↑ to %@", server)
        case .remoteCopy: return L10n.t("⇄ on %@", server)
        }
    }
}
