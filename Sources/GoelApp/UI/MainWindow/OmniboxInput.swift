import Foundation
import GoelCore

/// What the main window's omnibox holds: nothing, a search of the queue, or links to add.
/// Pure, so the rule that decides "is this a link or a search?" is tested rather than eyeballed.
/// It uses the same parser the Add sheet uses (`InboundAdd.parseSources`, which applies the scheme
/// allowlist), so the omnibox never recognises something Add would refuse.
enum OmniboxInput: Equatable {
    case empty
    /// Filters the list through the view model's `search` (including the `host:` token).
    case search(String)
    /// One or more recognised sources; the omnibox offers to add them instead of filtering.
    case links([DownloadSource])

    static func classify(_ text: String) -> OmniboxInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let sources = InboundAdd.parseSources(from: trimmed)
        return sources.isEmpty ? .search(text) : .links(sources)
    }

    var links: [DownloadSource] {
        if case .links(let sources) = self { return sources }
        return []
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }

    /// The search text the list should filter by: links and an empty box filter nothing.
    var searchText: String {
        if case .search(let text) = self { return text }
        return ""
    }

    /// "releases.ubuntu.com" for a URL, "magnet" for a magnet link.
    static func host(of source: DownloadSource) -> String {
        switch source {
        case .magnet: return "magnet"
        case .url(let url), .torrentFile(let url), .hlsStream(let url):
            return url.host ?? url.absoluteString
        }
    }

    /// The file name a source points at, for picking its artwork. Magnets have none.
    static func fileName(of source: DownloadSource) -> String {
        switch source {
        case .magnet: return ""
        case .url(let url), .torrentFile(let url), .hlsStream(let url):
            return url.lastPathComponent
        }
    }

    static func fileType(of source: DownloadSource) -> FileType {
        if case .magnet = source { return .magnet }
        return FileType.classify(fileName: fileName(of: source), isTorrent: source.kind == .torrent)
    }

    /// "HTTP · releases.ubuntu.com" — what the recognised-link row says it found.
    static func summary(of source: DownloadSource) -> String {
        "\(source.kind.badgeLabel) · \(host(of: source))"
    }
}
