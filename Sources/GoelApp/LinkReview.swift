import Foundation
import GoelCore

/// One row of the "Review N links" step: what the link is, where it's from and whether it's
/// already in the list. Size fills in later, one HEAD at a time.
struct LinkReviewItem: Identifiable, Equatable {
    /// The expanded line, which also keeps an inline `user:pass@` for the add path.
    let line: String
    let source: DownloadSource
    let name: String
    let host: String
    let category: GrabbedLink.Category
    /// The status of the row it duplicates, for the badge; nil when it's new.
    let duplicateStatus: String?
    var checked: Bool
    var size: Int64?
    /// Asked once, when the row first scrolls into view.
    var sizeRequested = false
    var sizeResolved = false

    var id: String { source.dedupKey }
}

enum LinkReview {

    /// The review never builds more rows than a pasted range could expand to.
    static let rowCap = BatchExpander.cap

    /// Lines expanded and parsed in order; repeats inside the batch collapse to the first, and
    /// links already in the list start unticked.
    static func items(from text: String,
                      duplicateStatus: (DownloadSource) -> String?) -> [LinkReviewItem] {
        var seen = Set<String>()
        var result: [LinkReviewItem] = []
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { BatchExpander.expand($0) }
        for line in lines {
            guard result.count < rowCap, let source = DownloadSource.parse(line),
                  seen.insert(source.dedupKey).inserted else { continue }
            let duplicate = duplicateStatus(source)
            result.append(LinkReviewItem(line: line, source: source, name: name(for: source),
                                         host: host(for: source), category: category(for: source),
                                         duplicateStatus: duplicate, checked: duplicate == nil))
        }
        return result
    }

    static func name(for source: DownloadSource) -> String {
        switch source {
        case .url(let url), .hlsStream(let url), .torrentFile(let url):
            let last = url.lastPathComponent
            return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
        case .magnet(let magnet):
            let items = URLComponents(string: magnet)?.queryItems ?? []
            // Magnet links form-encode the name: "+" is a space.
            let title = items.first { $0.name == "dn" }?.value?
                .replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            return (title?.isEmpty == false ? title : nil) ?? L10n.t("Magnet link")
        }
    }

    static func host(for source: DownloadSource) -> String {
        switch source {
        case .url(let url), .hlsStream(let url), .torrentFile(let url): return url.host?.lowercased() ?? ""
        case .magnet: return L10n.t("Peers")
        }
    }

    static func category(for source: DownloadSource) -> GrabbedLink.Category {
        switch source {
        case .magnet, .torrentFile: return .other
        case .hlsStream: return .video
        case .url(let url): return LinkExtractor.category(for: url) ?? .other
        }
    }

    /// Rows the filter box and the type chip leave showing; the query matches name or host.
    static func visible(_ items: [LinkReviewItem], query: String,
                        category: GrabbedLink.Category?) -> [LinkReviewItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (category == nil || item.category == category)
                && (needle.isEmpty || item.name.lowercased().contains(needle)
                    || item.host.contains(needle))
        }
    }

    /// Categories in first-seen order, for the chips.
    static func categories(in items: [LinkReviewItem]) -> [GrabbedLink.Category] {
        var seen: [GrabbedLink.Category] = []
        for item in items where !seen.contains(item.category) { seen.append(item.category) }
        return seen
    }

    struct Totals: Equatable {
        var count = 0
        var knownBytes: Int64 = 0
        var unknownSizes = 0
    }

    static func totals(_ items: [LinkReviewItem]) -> Totals {
        items.filter(\.checked).reduce(into: Totals()) { totals, item in
            totals.count += 1
            if let size = item.size { totals.knownBytes += size } else { totals.unknownSizes += 1 }
        }
    }

    /// "Add 12 · 3.4 GB · 120 GB free": the size says "at least" while some are still unknown.
    static func addTitle(_ totals: Totals, freeBytes: Int64?) -> String {
        var parts = [L10n.t("Add %d", totals.count)]
        if totals.knownBytes > 0 {
            parts.append(totals.unknownSizes > 0 ? L10n.t("≥ %@", totals.knownBytes.byteString)
                                                 : totals.knownBytes.byteString)
        }
        if let freeBytes { parts.append(L10n.t("%@ free", freeBytes.byteString)) }
        return parts.joined(separator: " · ")
    }

    /// The link grabber keeps its list readable; the note says what was left out.
    static func truncationNote(shown: Int, total: Int) -> String? {
        total > shown ? L10n.t("Showing first %1$d of %2$d links", shown, total) : nil
    }
}

/// Folders the user picked in Save to, newest first, so the next add offers them again.
enum RecentFolders {
    static let defaultsKey = "recentSaveFolders"
    static let limit = 5

    static func updated(_ list: [String], adding path: String, limit: Int = RecentFolders.limit) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return list }
        return Array(([trimmed] + list.filter { $0 != trimmed }).prefix(limit))
    }

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: defaultsKey) ?? []).filter { $0.hasPrefix("/") }
    }

    static func remember(_ path: String, in defaults: UserDefaults = .standard) {
        defaults.set(updated(load(defaults), adding: path), forKey: defaultsKey)
    }
}
