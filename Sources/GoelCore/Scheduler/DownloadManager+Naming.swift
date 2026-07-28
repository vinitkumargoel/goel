import Foundation

extension DownloadManager {

    /// Every branch must run through ``PathSafety/sanitizedName(_:fallback:)``: a magnet `dn=../../.ssh/authorized_keys` must not escape.
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

    private static func hlsDisplayName(_ url: URL) -> String {
        let generic: Set<String> = ["index", "playlist", "master", "prog_index", "chunklist", "main", "video", "stream"]
        let leaf = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let stem: String
        if !leaf.isEmpty, !generic.contains(leaf.lowercased()) {
            stem = leaf
        } else if !parent.isEmpty, parent != "/" {
            // Strip an extension the parent already carries, or `.mp4` below doubles it: `trailer.mp4.mp4`.
            let videoExts: Set<String> = ["mp4", "mkv", "avi", "mov", "webm", "m4v", "flv", "ts", "m3u8"]
            let ext = (parent as NSString).pathExtension.lowercased()
            stem = videoExts.contains(ext) ? (parent as NSString).deletingPathExtension : parent
        } else {
            stem = url.host ?? "video"
        }
        return PathSafety.sanitizedName(stem, fallback: "video") + ".mp4"
    }

    /// Fails closed: only an explicit `overwrite` keeps the name, so an unknown policy can't truncate a file.
    static func resolveName(_ base: String, in directory: String, policy: String) -> String {
        guard policy == "overwrite" else { return PathSafety.uniqueName(base: base, in: directory) }
        return base
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
