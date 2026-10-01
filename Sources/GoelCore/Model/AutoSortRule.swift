import Foundation

/// What to do with a download once it finishes. Open, Reveal and Open With are carried out by the
/// app (they need a window server); Move to and Run script by ``DownloadManager`` itself.
public struct WhenDone: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case nothing, open, reveal, openWith, moveTo, runScript
        public var id: String { rawValue }
    }

    public var kind: Kind
    /// The app for ``Kind/openWith``, the folder for ``Kind/moveTo``, the executable for ``Kind/runScript``.
    public var target: String?

    public init(_ kind: Kind, target: String? = nil) {
        self.kind = kind
        self.target = target
    }

    public static let nothing = WhenDone(.nothing)

    /// Kinds that need a target only count once they have one, so a half-edited choice is inert.
    public var isActionable: Bool {
        switch kind {
        case .nothing: return false
        case .open, .reveal: return true
        case .openWith, .moveTo, .runScript: return !(target ?? "").isEmpty
        }
    }
}

/// A user rule: when a new download matches, set where it goes and how it runs. Checked at add
/// time, before the default-folder rule, and only the first enabled match applies.
public struct AutoSortRule: Codable, Sendable, Hashable, Identifiable {

    public enum Field: String, Codable, Sendable, CaseIterable, Identifiable {
        case fileName, fileExtension, domain, url, size
        public var id: String { rawValue }
    }

    public enum Operator: String, Codable, Sendable, CaseIterable, Identifiable {
        case isEqual, contains, beginsWith, endsWith, isAnyOf, matchesRegex, largerThan, smallerThan
        public var id: String { rawValue }

        /// Size compares numbers; every other field compares text.
        public static func available(for field: Field) -> [Operator] {
            field == .size ? [.largerThan, .smallerThan]
                           : [.isEqual, .contains, .beginsWith, .endsWith, .isAnyOf, .matchesRegex]
        }
    }

    public struct Condition: Codable, Sendable, Hashable {
        public var field: Field
        public var op: Operator
        public var value: String

        public init(field: Field, op: Operator, value: String) {
            self.field = field
            self.op = op
            self.value = value
        }
    }

    public enum Match: String, Codable, Sendable, CaseIterable {
        case all, any
    }

    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: Match
    public var conditions: [Condition]

    public var folder: String?
    public var tag: String?
    public var speedLimitBytesPerSec: Int64?
    public var priority: FilePriority?
    public var startPaused: Bool
    public var whenDone: WhenDone?

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: Match = .all,
                conditions: [Condition], folder: String? = nil, tag: String? = nil,
                speedLimitBytesPerSec: Int64? = nil, priority: FilePriority? = nil,
                startPaused: Bool = false, whenDone: WhenDone? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.conditions = conditions
        self.folder = folder
        self.tag = tag
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.priority = priority
        self.startPaused = startPaused
        self.whenDone = whenDone
    }

    /// A rule with no conditions never matches: an empty "all" would otherwise catch everything.
    public func matches(_ candidate: AutoSortCandidate) -> Bool {
        guard enabled, !conditions.isEmpty else { return false }
        switch match {
        case .all: return conditions.allSatisfy { $0.matches(candidate) }
        case .any: return conditions.contains { $0.matches(candidate) }
        }
    }
}

/// What a rule looks at. Built from a source before anything is downloaded, so size is often unknown.
public struct AutoSortCandidate: Sendable, Hashable {
    public var fileName: String
    public var url: String
    public var host: String
    public var size: Int64?

    public init(fileName: String, url: String, host: String, size: Int64?) {
        self.fileName = fileName
        self.url = url
        self.host = host
        self.size = size
    }

    public init(source: DownloadSource, name: String, size: Int64?) {
        var host = ""
        if case .url(let u) = source { host = u.host?.lowercased() ?? "" }
        if case .hlsStream(let u) = source { host = u.host?.lowercased() ?? "" }
        self.init(fileName: name, url: source.locator, host: host, size: size)
    }

    public var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
}

extension AutoSortRule.Condition {

    public func matches(_ c: AutoSortCandidate) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if field == .size { return matchesSize(c.size, needle) }
        let text: String
        switch field {
        case .fileName: text = c.fileName
        case .fileExtension: text = c.fileExtension
        case .domain: text = c.host
        case .url: text = c.url
        case .size: return false
        }
        return matchesText(text, needle)
    }

    private func matchesText(_ text: String, _ needle: String) -> Bool {
        let hay = text.lowercased()
        let lowered = field == .fileExtension ? Self.bareExtension(needle) : needle.lowercased()
        switch op {
        case .isEqual: return hay == lowered
        case .contains: return hay.contains(lowered)
        case .beginsWith: return hay.hasPrefix(lowered)
        // A domain "ends with example.com" must not match "badexample.com".
        case .endsWith:
            if field == .domain { return hay == lowered || hay.hasSuffix("." + lowered) }
            return hay.hasSuffix(lowered)
        case .isAnyOf:
            let options = needle.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
                .map { field == .fileExtension ? Self.bareExtension(String($0)) : $0.lowercased() }
            return options.contains(hay)
        case .matchesRegex:
            return RuleRegex.matches(pattern: needle, in: text)
        case .largerThan, .smallerThan:
            return false
        }
    }

    /// Unknown size matches neither side, so "smaller than 10 MB" never catches an unsized torrent.
    private func matchesSize(_ size: Int64?, _ needle: String) -> Bool {
        guard let size, let limit = Self.parseBytes(needle) else { return false }
        switch op {
        case .largerThan: return size > limit
        case .smallerThan: return size < limit
        default: return false
        }
    }

    static func bareExtension(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix(".") || s.hasPrefix("*") { s.removeFirst() }
        return s
    }

    /// "10 MB", "1.5GB", "500k", "2048": decimal units, the same as the sizes shown in the app.
    public static func parseBytes(_ raw: String) -> Int64? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "")
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let unit = s.dropFirst(digits.count).replacingOccurrences(of: "b", with: "")
        let scale: Double
        switch unit {
        case "": scale = 1
        case "k": scale = 1_000
        case "m": scale = 1_000_000
        case "g": scale = 1_000_000_000
        case "t": scale = 1_000_000_000_000
        default: return nil
        }
        let bytes = number * scale
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }
}

public enum AutoSortRules {

    public static func firstMatch(in rules: [AutoSortRule], for candidate: AutoSortCandidate) -> AutoSortRule? {
        rules.first { $0.matches(candidate) }
    }

    /// For the editor's "would match N in your history" line.
    public static func matchCount(of rule: AutoSortRule, in candidates: [AutoSortCandidate]) -> Int {
        var enabled = rule
        enabled.enabled = true
        return candidates.reduce(0) { $0 + (enabled.matches($1) ? 1 : 0) }
    }
}

/// User-typed regexes, bounded three ways: pattern length, haystack length, and a wall-clock
/// deadline enforced through ICU's progress callback, so `(a+)+$` can't stall an add or the
/// history preview. Compiled patterns are cached; a pattern that doesn't compile never matches.
public enum RuleRegex {
    public static let maxPatternLength = 512
    public static let maxHaystackLength = 2_048
    public static let deadline: TimeInterval = 0.05

    private static let cache = NSCache<NSString, NSRegularExpression>()
    private static let invalid = NSCache<NSString, NSNumber>()

    public static func matches(pattern: String, in text: String) -> Bool {
        // Over-long text never matches: cutting it short would let an anchored pattern match a
        // string the user never wrote (`(a+)+$` matches 2 KB of the 5 KB "aaa…!").
        guard pattern.count <= maxPatternLength, text.utf16.count <= maxHaystackLength,
              let regex = compiled(pattern) else { return false }
        let hay = text
        let start = Date()
        var found = false
        regex.enumerateMatches(in: hay, options: [.reportProgress],
                               range: NSRange(hay.startIndex..., in: hay)) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if Date().timeIntervalSince(start) > deadline {
                // Out of time: stop and count it as no match.
                stop.pointee = true
            }
        }
        return found
    }

    static func compiled(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if invalid.object(forKey: key) != nil { return nil }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            invalid.setObject(1, forKey: key)
            return nil
        }
        cache.setObject(regex, forKey: key)
        return regex
    }
}
