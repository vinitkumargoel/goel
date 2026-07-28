import Foundation

public enum BatchExpander {

    public static let cap = 500

    public static func expand(_ line: String, cap: Int = BatchExpander.cap) -> [String] {
        guard !line.lowercased().hasPrefix("magnet:") else { return [line] }
        var results = [line]
        // Each pass multiplies the list, so the cap must be checked on every round.
        var expandedAny = true
        while expandedAny {
            expandedAny = false
            var next: [String] = []
            for candidate in results {
                if let variants = expandFirstPattern(in: candidate, cap: cap) {
                    guard next.count + variants.count <= cap else { return [line] }
                    next.append(contentsOf: variants)
                    expandedAny = true
                } else {
                    next.append(candidate)
                }
            }
            results = next
            if results.count > cap { return [line] }
        }
        return results
    }

    /// Over-cap ranges are rejected *before* materializing, so `[1-999999]` never allocates a million rows.
    private static func expandFirstPattern(in line: String, cap: Int) -> [String]? {
        if let range = firstNumericRange(in: line) {
            let inner = String(line[line.index(after: range.lowerBound)..<line.index(before: range.upperBound)])
            let bounds = inner.split(separator: "-")
            let startToken = String(bounds[0]), endToken = String(bounds[1])
            guard let start = Int(startToken), let end = Int(endToken), start <= end,
                  end - start < cap else { return nil }
            let width = startToken.hasPrefix("0") ? startToken.count : 0
            return (start...end).map { n in
                let number = width > 0 ? String(format: "%0\(width)d", n) : String(n)
                return line.replacingCharacters(in: range, with: number)
            }
        }
        if let range = firstAlternation(in: line) {
            let inner = String(line[line.index(after: range.lowerBound)..<line.index(before: range.upperBound)])
            let options = inner.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard options.count > 1, options.allSatisfy({ !$0.isEmpty }) else { return nil }
            return options.map { line.replacingCharacters(in: range, with: $0) }
        }
        return nil
    }

    /// Digits-only on both sides, or an IPv6 host literal (`http://[::1]/…`) would match.
    private static func firstNumericRange(in line: String) -> Range<String.Index>? {
        line.range(of: #"\[[0-9]+-[0-9]+\]"#, options: .regularExpression)
    }

    private static func firstAlternation(in line: String) -> Range<String.Index>? {
        line.range(of: #"\{[^{}]*,[^{}]*\}"#, options: .regularExpression)
    }
}

public struct PlaylistItem: Sendable, Hashable, Identifiable {

    public let id: String
    public var title: String
    public var url: String
    public var durationSeconds: Int?
    public var index: Int

    public init(id: String, title: String, url: String,
                durationSeconds: Int? = nil, index: Int) {
        self.id = id
        self.title = title
        self.url = url
        self.durationSeconds = durationSeconds
        self.index = index
    }

    public var durationText: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let h = durationSeconds / 3600, m = (durationSeconds % 3600) / 60, s = durationSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

public struct PlaylistExpansion: Sendable, Hashable {
    public var title: String
    public var items: [PlaylistItem]
    /// The tail was dropped at ``PlaylistExpander/cap`` — the UI must say so, or a partial list reads as complete.
    public var truncated: Bool

    public init(title: String, items: [PlaylistItem], truncated: Bool = false) {
        self.title = title
        self.items = items
        self.truncated = truncated
    }
}

public enum PlaylistExpander {

    public static let cap = 1_000

    /// A channel expands into tab playlists ("Videos", "Shorts") holding the entries — one level is normal, two is not.
    private static let maxNestingDepth = 2

    public static func looksLikePlaylist(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return false }

        if components.queryItems?.contains(where: {
            $0.name.lowercased() == "list" && !($0.value ?? "").isEmpty
        }) == true { return true }

        let path = components.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)

        let containerSegments: Set<String> = [
            "playlist", "playlists", "sets", "album", "channel", "showcase",
        ]
        if segments.contains(where: { containerSegments.contains($0) }) { return true }

        let containerPrefixes = ["/c/", "/user/", "/@", "/show/"]
        if containerPrefixes.contains(where: { path.hasPrefix($0) }) { return true }

        // Suffix-matched, not bare segments, or a plain `/videos/holiday.mp4` would match too.
        let containerSuffixes = ["/videos", "/shorts", "/streams", "/releases"]
        if containerSuffixes.contains(where: { path.hasSuffix($0) }) { return true }

        if host.contains("youtube."), path.hasPrefix("/@") { return true }
        return false
    }

    public static func parseFlatPlaylist(_ text: String) -> PlaylistExpansion? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parseFlatPlaylist(data)
    }

    /// Data overload: a `Data` → `String` round-trip is lossy on titles that are not valid UTF-8.
    public static func parseFlatPlaylist(_ data: Data) -> PlaylistExpansion? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard root["entries"] is [Any] || (root["_type"] as? String) == "playlist" else {
            return nil
        }
        var items: [PlaylistItem] = []
        var overflowed = false
        collect(from: root, depth: 0, into: &items, overflowed: &overflowed)
        let title = (root["title"] as? String)
            ?? (root["id"] as? String)
            ?? "Playlist"
        return PlaylistExpansion(title: title, items: items, truncated: overflowed)
    }

    private static func collect(from node: [String: Any], depth: Int,
                                into items: inout [PlaylistItem], overflowed: inout Bool) {
        guard let entries = node["entries"] as? [Any] else { return }
        for entry in entries {
            guard items.count < cap else { overflowed = true; return }
            guard let entry = entry as? [String: Any] else { continue }
            if entry["entries"] is [Any] {
                guard depth + 1 < maxNestingDepth else { overflowed = true; continue }
                collect(from: entry, depth: depth + 1, into: &items, overflowed: &overflowed)
                continue
            }
            guard let link = (entry["webpage_url"] as? String) ?? (entry["url"] as? String),
                  !link.isEmpty else { continue }
            let identifier = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? link
            items.append(PlaylistItem(
                id: identifier,
                title: (entry["title"] as? String) ?? identifier,
                url: link,
                durationSeconds: duration(from: entry["duration"]),
                index: items.count + 1))
        }
    }

    private static func duration(from value: Any?) -> Int? {
        if let n = value as? Int { return n > 0 ? n : nil }
        if let d = value as? Double, d > 0 { return Int(d.rounded()) }
        return nil
    }

    public static func parsePrintListing(_ text: String) -> [PlaylistItem] {
        var items: [PlaylistItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard items.count < cap else { break }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { continue }
            let identifier = fields[0], title = fields[1], link = fields[2]
            guard !link.isEmpty, link != "NA" else { continue }
            let seconds = fields.count >= 4 ? Int(fields[3].split(separator: ".").first.map(String.init) ?? "") : nil
            items.append(PlaylistItem(
                id: identifier.isEmpty || identifier == "NA" ? link : identifier,
                title: title.isEmpty || title == "NA" ? identifier : title,
                url: link,
                durationSeconds: (seconds ?? 0) > 0 ? seconds : nil,
                index: items.count + 1))
        }
        return items
    }
}

public struct MediaFormat: Sendable, Hashable, Identifiable {

    /// Handed straight back to `-f`, so it must survive parsing verbatim.
    public let id: String
    public var ext: String
    public var resolution: String
    public var height: Int?
    public var fps: Int?
    public var fileSizeBytes: Int64?
    public var isApproximateSize: Bool
    public var vcodec: String?
    public var acodec: String?
    public var note: String
    public var hasVideo: Bool
    public var hasAudio: Bool

    public init(id: String, ext: String, resolution: String, height: Int? = nil,
                fps: Int? = nil, fileSizeBytes: Int64? = nil, isApproximateSize: Bool = false,
                vcodec: String? = nil, acodec: String? = nil, note: String = "",
                hasVideo: Bool = true, hasAudio: Bool = true) {
        self.id = id
        self.ext = ext
        self.resolution = resolution
        self.height = height
        self.fps = fps
        self.fileSizeBytes = fileSizeBytes
        self.isApproximateSize = isApproximateSize
        self.vcodec = vcodec
        self.acodec = acodec
        self.note = note
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    public var isAudioOnly: Bool { hasAudio && !hasVideo }
    public var isVideoOnly: Bool { hasVideo && !hasAudio }

    /// A video-only format looks like the obvious "1080p" pick but yields a silent file unless muxed.
    public var isSelfContained: Bool { hasVideo && hasAudio }

    public var qualityLabel: String {
        guard let height else { return isAudioOnly ? "audio" : resolution }
        let fpsSuffix = (fps ?? 0) > 30 ? "\(fps!)" : ""
        return "\(height)p\(fpsSuffix)"
    }
}

public enum MediaFormatTable {

    public static func parse(_ text: String) -> [MediaFormat] {
        var formats: [MediaFormat] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard isFormatRow(line) else { continue }
            if let format = line.contains("|") ? parseModernRow(line) : parseLegacyRow(line) {
                formats.append(format)
            }
        }
        return formats
    }

    private static func isFormatRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("-") { return false }
        if trimmed.hasPrefix("ID ") || trimmed.hasPrefix("format code") { return false }
        if trimmed.hasPrefix("WARNING") || trimmed.hasPrefix("ERROR") { return false }
        return true
    }

    private static func parseModernRow(_ line: String) -> MediaFormat? {
        // "audio only"/"video only" are two-word cells; fuse them or whitespace tokenisation splits them.
        let fused = line
            .replacingOccurrences(of: "audio only", with: "audio\u{2060}only")
            .replacingOccurrences(of: "video only", with: "video\u{2060}only")
        let segments = fused.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2 else { return nil }

        let head = tokens(segments[0])
        guard head.count >= 3 else { return nil }
        let identifier = head[0], ext = head[1]
        let resolutionToken = head[2]
        // Storyboard/thumbnail rows (`mhtml`, `48x27`) are not downloadable media.
        guard ext.lowercased() != "mhtml" else { return nil }

        // FPS and CH are both bare ints: the number after RESOLUTION is fps only when there is a picture.
        let resolvedHeight = height(fromResolution: resolutionToken)
        let fps = resolvedHeight == nil ? nil
            : head.dropFirst(3).compactMap { Int($0) }.first.flatMap { $0 > 0 ? $0 : nil }

        let middle = tokens(segments[1])
        var size: Int64?
        var approximate = false
        var index = 0
        while index < middle.count {
            let token = middle[index]
            if token == "~" { approximate = true; index += 1; continue }
            if let parsed = byteCount(token) {
                size = parsed
                approximate = approximate || token.hasPrefix("~")
                break
            }
            index += 1
        }

        let tail = segments.count >= 3 ? tokens(segments[2]) : []
        let hasVideo = !isMarker(resolutionToken, "audio")
                    && !(tail.first.map { isMarker($0, "audio") } ?? false)
        let hasAudio = !tail.contains { isMarker($0, "video") }
        let codecs = tail.filter { isCodecToken($0) }
        let vcodec = hasVideo ? codecs.first : nil
        let acodec = hasAudio ? (hasVideo ? codecs.dropFirst().first : codecs.first) : nil
        let note = tail
            .filter { !isCodecToken($0) && !isBitrateToken($0) && !isMarker($0, nil) }
            .joined(separator: " ")

        return MediaFormat(
            id: identifier, ext: ext,
            resolution: unfuse(resolutionToken),
            height: resolvedHeight,
            fps: fps, fileSizeBytes: size, isApproximateSize: approximate,
            vcodec: vcodec, acodec: acodec,
            note: unfuse(note).trimmingCharacters(in: .whitespaces),
            hasVideo: hasVideo, hasAudio: hasAudio)
    }

    private static func parseLegacyRow(_ line: String) -> MediaFormat? {
        let fused = line
            .replacingOccurrences(of: "audio only", with: "audio\u{2060}only")
            .replacingOccurrences(of: "video only", with: "video\u{2060}only")
        let parts = tokens(fused)
        guard parts.count >= 3 else { return nil }
        let ext = parts[1]
        guard ext.lowercased() != "mhtml" else { return nil }
        let resolutionToken = parts[2]
        let rest = Array(parts.dropFirst(3))
        let hasVideo = !isMarker(resolutionToken, "audio")
        let hasAudio = !rest.contains { isMarker($0, "video") }
        let size = rest.compactMap { byteCount($0.trimmingCharacters(in: .punctuationCharacters)) }.last
        let note = rest
            .filter { !isBitrateToken($0) && !isMarker($0, nil) && byteCount($0) == nil }
            .joined(separator: " ")

        return MediaFormat(
            id: parts[0], ext: ext,
            resolution: unfuse(resolutionToken),
            height: height(fromResolution: resolutionToken),
            fps: nil, fileSizeBytes: size, isApproximateSize: false,
            vcodec: nil, acodec: nil,
            note: unfuse(note).trimmingCharacters(in: .whitespaces),
            hasVideo: hasVideo, hasAudio: hasAudio)
    }

    private static func tokens(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func unfuse(_ token: String) -> String {
        token.replacingOccurrences(of: "\u{2060}", with: " ")
    }

    /// Prefix-compared, not equal: the legacy layout runs these into the note as `video only,`.
    private static func isMarker(_ token: String, _ kind: String?) -> Bool {
        guard let kind else {
            return token.hasPrefix("audio\u{2060}only") || token.hasPrefix("video\u{2060}only")
        }
        return token.hasPrefix("\(kind)\u{2060}only")
    }

    private static func height(fromResolution token: String) -> Int? {
        let parts = token.lowercased().split(separator: "x")
        guard parts.count == 2, let h = Int(parts[1]) else { return nil }
        return h
    }

    private static let dotlessCodecs: Set<String> = [
        "opus", "vorbis", "flac", "mp3", "aac", "vp8", "vp9", "ec-3", "ac-3", "none",
    ]

    private static func isCodecToken(_ token: String) -> Bool {
        if dotlessCodecs.contains(token.lowercased()) { return true }
        guard token.contains("."), let first = token.first else { return false }
        return first.isLetter && byteCount(token) == nil
    }

    private static func isBitrateToken(_ token: String) -> Bool {
        let body = token.hasPrefix("~") ? String(token.dropFirst()) : token
        guard body.hasSuffix("k"), body.count > 1 else { return false }
        return Double(body.dropLast()) != nil
    }

    /// Per yt-dlp: `iB` suffixes are binary (1024), bare `B` suffixes decimal (1000).
    static func byteCount(_ token: String) -> Int64? {
        let body = token.hasPrefix("~") ? String(token.dropFirst()) : token
        let units: [(String, Double)] = [
            ("KiB", 1024), ("MiB", 1_048_576), ("GiB", 1_073_741_824), ("TiB", 1_099_511_627_776),
            ("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000), ("TB", 1_000_000_000_000),
        ]
        for (suffix, multiplier) in units where body.hasSuffix(suffix) {
            guard let value = Double(body.dropLast(suffix.count)), value >= 0 else { return nil }
            return Int64(value * multiplier)
        }
        // Never a bare number: unsuffixed tokens are bitrates or column indices, not sizes.
        if body.hasSuffix("B"), let value = Double(body.dropLast()) { return Int64(value) }
        return nil
    }
}
