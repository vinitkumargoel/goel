import Foundation
import GoelCore

/// The Add sheet's "Needs 48 GB · 12 GB free" line. The engines only check free space once a
/// download is running, and then only for HTTP; this warns before anything is queued.
enum DiskSpaceCheck {

    struct Verdict: Equatable {
        let needed: Int64
        let available: Int64
        var isSufficient: Bool { needed <= available }
    }

    static func verdict(needed: Int64?, available: Int64?) -> Verdict? {
        guard let needed, needed > 0, let available, available >= 0 else { return nil }
        return Verdict(needed: needed, available: available)
    }

    /// Where a download added with "Automatic" will land, for the free-space preview. Mirrors
    /// `DownloadManager.defaultDirectory(for:)`, which GoelCore keeps private; a change to the
    /// folder rules there must be repeated here.
    static func automaticFolder(for source: DownloadSource, suggestedName: String,
                                settings: AppSettings) -> String {
        let base = settings.defaultSaveDirectory
        switch settings.defaultFolderRule {
        case "byType", "automatic":
            return (base as NSString).appendingPathComponent(categoryFolder(kind: source.kind,
                                                                            name: suggestedName))
        case "bySource":
            return (base as NSString).appendingPathComponent(source.kind == .torrent ? "Torrents"
                                                                                      : "HTTP Downloads")
        default:
            return base
        }
    }

    static func categoryFolder(kind: DownloadKind, name: String) -> String {
        if kind == .torrent { return "Torrents" }
        let lower = name.lowercased()
        func ext(_ list: [String]) -> Bool { list.contains { lower.hasSuffix(".\($0)") } }
        if ext(["mkv", "mp4", "avi", "mov", "webm", "m4v", "flv"]) { return "Video" }
        if ext(["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus"]) { return "Audio" }
        if ext(["jpg", "jpeg", "png", "gif", "webp", "heic", "svg"]) { return "Images" }
        if ext(["iso", "dmg", "pkg", "app", "exe", "deb", "msi", "xip"]) { return "Software" }
        if ext(["zip", "gz", "tar", "7z", "rar", "bz2", "xz"]) { return "Archives" }
        if ext(["pdf", "doc", "docx", "txt", "epub", "csv", "xlsx"]) { return "Documents" }
        return "Other"
    }

    static func message(for verdict: Verdict) -> String {
        L10n.t("Needs %1$@ · %2$@ free", verdict.needed.byteString, verdict.available.byteString)
    }

    static func spokenMessage(for verdict: Verdict) -> String {
        verdict.isSufficient
            ? L10n.t("Needs %1$@, %2$@ free", A11y.bytes(verdict.needed), A11y.bytes(verdict.available))
            : L10n.t("Not enough space. Needs %1$@, only %2$@ free", A11y.bytes(verdict.needed), A11y.bytes(verdict.available))
    }

    /// Free bytes on the volume holding `path`, as Finder reports it (purgeable space counts).
    /// The folder may not exist yet — downloads create it — so the nearest existing ancestor is asked.
    static func availableCapacity(forFolder path: String) -> Int64? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                      .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
