import Foundation

// MARK: - Name & folder derivation

/// Pure, source-derived naming helpers. Split out of ``DownloadManager`` so the
/// scheduler proper stays focused on the queue; every name flows through
/// ``PathSafety/sanitizedName(_:fallback:)`` so a hostile filename can never
/// escape the save directory.
extension DownloadManager {

    /// A sensible — and **safe** — initial display name derived purely from the
    /// source. Every branch runs through ``PathSafety/sanitizedName(_:fallback:)``
    /// so a hostile filename (e.g. a magnet `dn=../../.ssh/authorized_keys`) can
    /// never become a `name` that escapes the save directory.
    static func defaultName(for source: DownloadSource) -> String {
        switch source {
        case let .url(url):
            let last = url.lastPathComponent
            let base = (last.isEmpty || last == "/") ? (url.host ?? "download") : last
            return PathSafety.sanitizedName(base, fallback: url.host ?? "download")
        case let .torrentFile(url):
            let name = url.deletingPathExtension().lastPathComponent
            return PathSafety.sanitizedName(name, fallback: "torrent")
        case let .magnet(magnet):
            return magnetDisplayName(magnet) ?? "Magnet download"
        case let .hlsStream(url):
            return hlsDisplayName(url)
        }
    }

    /// A coarse content category derived from the source's apparent file
    /// extension (torrents bucket together). Mirrors the app's file-type buckets
    /// without importing the app layer.
    static func categoryFolder(for source: DownloadSource) -> String {
        if source.kind == .torrent { return "Torrents" }
        let name = defaultName(for: source).lowercased()
        func ext(_ list: [String]) -> Bool { list.contains { name.hasSuffix(".\($0)") } }
        if ext(["mkv", "mp4", "avi", "mov", "webm", "m4v", "flv"]) { return "Video" }
        if ext(["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus"]) { return "Audio" }
        if ext(["jpg", "jpeg", "png", "gif", "webp", "heic", "svg"]) { return "Images" }
        if ext(["iso", "dmg", "pkg", "app", "exe", "deb", "msi", "xip"]) { return "Software" }
        if ext(["zip", "gz", "tar", "7z", "rar", "bz2", "xz"]) { return "Archives" }
        if ext(["pdf", "doc", "docx", "txt", "epub", "csv", "xlsx"]) { return "Documents" }
        return "Other"
    }

    /// A `.mp4` name for an HLS stream. The playlist file is usually a generic
    /// `index.m3u8` / `playlist.m3u8`, so prefer the parent path component (the
    /// title folder), falling back to the host.
    private static func hlsDisplayName(_ url: URL) -> String {
        let generic: Set<String> = ["index", "playlist", "master", "prog_index", "chunklist", "main", "video", "stream"]
        let leaf = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let stem: String
        if !leaf.isEmpty, !generic.contains(leaf.lowercased()) {
            stem = leaf
        } else if !parent.isEmpty, parent != "/" {
            stem = parent
        } else {
            stem = url.host ?? "video"
        }
        return PathSafety.sanitizedName(stem, fallback: "video") + ".mp4"
    }

    /// Apply the file-conflict policy to a freshly derived name. `overwrite`
    /// (or anything unrecognised) keeps the name as-is; `rename` appends
    /// ` (1)`, ` (2)`, … before the extension until the path is free. Bounded so
    /// a pathological directory can never spin forever.
    static func resolveName(_ base: String, in directory: String, policy: String) -> String {
        guard policy == "rename" else { return base }
        return PathSafety.uniqueName(base: base, in: directory)
    }

    private static func magnetDisplayName(_ magnet: String) -> String? {
        guard
            let components = URLComponents(string: magnet),
            let value = components.queryItems?.first(where: { $0.name == "dn" })?.value,
            !value.isEmpty
        else { return nil }
        let cleaned = value.replacingOccurrences(of: "+", with: " ")
        return PathSafety.sanitizedName(cleaned, fallback: "Magnet download")
    }
}
