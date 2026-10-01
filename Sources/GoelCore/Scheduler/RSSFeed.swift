import Foundation

public struct RSSFeed: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    /// "Must contain": the whole text, or alternatives separated by `|`. Empty matches everything.
    public var titlePattern: String
    public var enabled: Bool

    public var startPaused: Bool

    /// Any of these `|`-separated terms in a title skips it.
    public var mustNotContain: String
    /// qBittorrent's syntax: `1x2;8-15;20-` (season 1, episodes 2, 8…15 and 20 onwards).
    public var episodeFilter: String
    /// Where matches are saved; empty follows the default folder rule.
    public var saveDirectory: String
    /// Tag added to every download this feed starts; empty adds none.
    public var tag: String
    /// Shown in the RSS sidebar; empty falls back to the host.
    public var name: String

    public init(id: UUID = UUID(), url: String, titlePattern: String = "",
                enabled: Bool = true, startPaused: Bool = false,
                mustNotContain: String = "", episodeFilter: String = "",
                saveDirectory: String = "", tag: String = "", name: String = "") {
        self.id = id
        self.url = url
        self.titlePattern = titlePattern
        self.enabled = enabled
        self.startPaused = startPaused
        self.mustNotContain = mustNotContain
        self.episodeFilter = episodeFilter
        self.saveDirectory = saveDirectory
        self.tag = tag
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, titlePattern, enabled, startPaused
        case mustNotContain, episodeFilter, saveDirectory, tag, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        titlePattern = try c.decodeIfPresent(String.self, forKey: .titlePattern) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startPaused = try c.decodeIfPresent(Bool.self, forKey: .startPaused) ?? false
        mustNotContain = try c.decodeIfPresent(String.self, forKey: .mustNotContain) ?? ""
        episodeFilter = try c.decodeIfPresent(String.self, forKey: .episodeFilter) ?? ""
        saveDirectory = try c.decodeIfPresent(String.self, forKey: .saveDirectory) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return URLComponents(string: url)?.host ?? url
    }
}

/// Whether a feed item's title passes a feed's rule. Shared by the poller and the rule editor's preview.
public enum RSSRuleMatcher {

    public static func matches(title: String, feed: RSSFeed) -> Bool {
        matches(title: title, mustContain: feed.titlePattern,
                mustNotContain: feed.mustNotContain, episodeFilter: feed.episodeFilter)
    }

    public static func matches(title: String, mustContain: String,
                               mustNotContain: String, episodeFilter: String) -> Bool {
        let include = terms(mustContain)
        if !include.isEmpty, !include.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        if terms(mustNotContain).contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        let filter = episodeFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return true }
        guard let episode = episode(in: title),
              let parsed = EpisodeFilter(filter) else { return false }
        return parsed.contains(season: episode.season, episode: episode.episode)
    }

    static func terms(_ raw: String) -> [String] {
        raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `S01E05`, `s1e5` or `1x05` anywhere in the title.
    public static func episode(in title: String) -> (season: Int, episode: Int)? {
        let patterns = [#"[Ss](\d{1,2})\s?[Ee](\d{1,3})"#, #"\b(\d{1,2})x(\d{1,3})\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(title.startIndex..., in: title)
            guard let m = regex.firstMatch(in: title, range: range),
                  let sr = Range(m.range(at: 1), in: title), let er = Range(m.range(at: 2), in: title),
                  let s = Int(title[sr]), let e = Int(title[er]) else { continue }
            return (s, e)
        }
        return nil
    }

    /// `SxA;B-C;D-` — one season, then episodes, single values or ranges (open-ended with a trailing `-`).
    public struct EpisodeFilter: Equatable {
        public var season: Int
        public var ranges: [ClosedRange<Int>]

        public init?(_ raw: String) {
            let parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = parts.first else { return nil }
            let head = first.lowercased().split(separator: "x", maxSplits: 1).map(String.init)
            guard head.count == 2, let season = Int(head[0]) else { return nil }
            self.season = season
            var ranges: [ClosedRange<Int>] = []
            for spec in [head[1]] + parts.dropFirst() {
                guard let r = Self.range(spec) else { return nil }
                ranges.append(r)
            }
            self.ranges = ranges
        }

        static func range(_ spec: String) -> ClosedRange<Int>? {
            let s = spec.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix("-"), let lo = Int(s.dropLast()) { return lo...Int.max }
            if s.hasPrefix("-"), let hi = Int(s.dropFirst()) { return 0...hi }
            let bounds = s.split(separator: "-").map { Int($0) }
            if bounds.count == 1, let v = bounds[0] { return v...v }
            if bounds.count == 2, let lo = bounds[0], let hi = bounds[1], lo <= hi { return lo...hi }
            return nil
        }

        public func contains(season: Int, episode: Int) -> Bool {
            season == self.season && ranges.contains { $0.contains(episode) }
        }
    }
}
