import Foundation

/// Expands batch shorthand in a pasted line: `file[01-20].zip` ranges (padded to the start bound's width)
/// and `file.{iso,sig}` alternations, cartesian-combined and capped; over-cap and magnets pass verbatim.
public enum BatchExpander {

    /// The most tasks a single pasted line may expand into.
    public static let cap = 500

    public static func expand(_ line: String, cap: Int = BatchExpander.cap) -> [String] {
        guard !line.lowercased().hasPrefix("magnet:") else { return [line] }
        var results = [line]
        // Repeatedly expand the first pattern until none remain. Each pass
        // multiplies the list, so guard the cap on every round.
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

    /// Expand the leftmost `[N-M]` or `{a,b,…}` pattern, or nil if none. A range wider than `cap` is
    /// not-a-pattern, checked *before* materializing so `[1-999999]` never allocates a million rows.
    private static func expandFirstPattern(in line: String, cap: Int) -> [String]? {
        if let range = firstNumericRange(in: line) {
            let inner = String(line[line.index(after: range.lowerBound)..<line.index(before: range.upperBound)])
            let bounds = inner.split(separator: "-")
            let startToken = String(bounds[0]), endToken = String(bounds[1])
            guard let start = Int(startToken), let end = Int(endToken), start <= end,
                  end - start < cap else { return nil }
            // `[01-20]` keeps the leading-zero width; `[1-20]` doesn't pad.
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

    /// The leftmost `[digits-digits]` span. Strictly digits on both sides, so an
    /// IPv6 host literal (`http://[::1]/…`) or a stray bracket never matches.
    private static func firstNumericRange(in line: String) -> Range<String.Index>? {
        line.range(of: #"\[[0-9]+-[0-9]+\]"#, options: .regularExpression)
    }

    /// The leftmost `{a,b,…}` span with at least one comma and no nesting.
    private static func firstAlternation(in line: String) -> Range<String.Index>? {
        line.range(of: #"\{[^{}]*,[^{}]*\}"#, options: .regularExpression)
    }
}

// MARK: - Playlist / channel expansion
// Same "one pasted URL → rows to tick" seam as `BatchExpander`, oracle is yt-dlp text; pure, no network.

/// One entry of an expanded playlist — enough to show a checklist row and, once
/// ticked, to queue a normal download.
public struct PlaylistItem: Sendable, Hashable, Identifiable {

    /// The extractor's own id (`dQw4w9WgXcQ`). Falls back to the URL when an
    /// extractor omits it, so the value stays usable as a `ForEach` identity.
    public let id: String
    public var title: String
    public var url: String
    /// Runtime in whole seconds when the listing carried one. `--flat-playlist` frequently omits it,
    /// so nil means "unknown", never zero.
    public var durationSeconds: Int?
    /// 1-based position in the playlist, preserved so the checklist can show the
    /// user the same ordering the site does even after they filter or sort.
    public var index: Int

    public init(id: String, title: String, url: String,
                durationSeconds: Int? = nil, index: Int) {
        self.id = id
        self.title = title
        self.url = url
        self.durationSeconds = durationSeconds
        self.index = index
    }

    /// `7:12` / `1:03:44`, or nil when the listing carried no duration.
    public var durationText: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let h = durationSeconds / 3600, m = (durationSeconds % 3600) / 60, s = durationSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// A parsed playlist: its own title plus the items the user picks from.
public struct PlaylistExpansion: Sendable, Hashable {
    public var title: String
    public var items: [PlaylistItem]
    /// Source listed more than ``PlaylistExpander/cap`` and the tail was dropped. The UI must say so —
    /// showing 1 000 of a 4 000-video channel as "everything" is a lie found out only after the fact.
    public var truncated: Bool

    public init(title: String, items: [PlaylistItem], truncated: Bool = false) {
        self.title = title
        self.items = items
        self.truncated = truncated
    }
}

/// Parses the playlist listings yt-dlp emits, and recognises playlist-shaped URLs
/// so the add-flow knows when to offer expansion at all.
public enum PlaylistExpander {

    /// Max items one pasted playlist may expand into. A channel can hold tens of thousands; materialising
    /// all would freeze the checklist and bury the queue. Above `BatchExpander.cap` — a real listing.
    public static let cap = 1_000

    /// Nesting depth followed: a channel expands into tab playlists ("Videos", "Shorts", "Live") holding
    /// the entries, so one level is normal and two is already pathological.
    private static let maxNestingDepth = 2

    // MARK: Recognition

    /// Whether `raw` looks like a playlist/channel/album/user page. Purely syntactic; non-http(s) rejected.
    /// A false negative only hides the button; a false positive spawns a pointless yt-dlp run on a file.
    public static func looksLikePlaylist(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return false }

        // `list=` is the unambiguous YouTube playlist marker, including on `watch?v=…&list=…`
        // (genuinely both a single video and a playlist — the picker lets the user choose).
        if components.queryItems?.contains(where: {
            $0.name.lowercased() == "list" && !($0.value ?? "").isEmpty
        }) == true { return true }

        let path = components.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)

        // Words that mean "container" wherever they appear in the path:
        // soundcloud.com/artist/sets/album, vimeo.com/album/123, …
        let containerSegments: Set<String> = [
            "playlist", "playlists", "sets", "album", "channel", "showcase",
        ]
        if segments.contains(where: { containerSegments.contains($0) }) { return true }

        // Container shapes anchored to the path start: `/videos` as a bare *segment* would also match
        // an ordinary /videos/clip.mp4 file URL.
        let containerPrefixes = ["/c/", "/user/", "/@", "/show/"]
        if containerPrefixes.contains(where: { path.hasPrefix($0) }) { return true }

        // Channel sub-tabs: `/@handle/videos`, `/c/name/streams`, … Matched as a
        // suffix so a plain `/videos/holiday.mp4` is left alone.
        let containerSuffixes = ["/videos", "/shorts", "/streams", "/releases"]
        if containerSuffixes.contains(where: { path.hasSuffix($0) }) { return true }

        // Bare `/@handle` on a YouTube host, already covered above but kept
        // explicit because the handle form is the common modern channel link.
        if host.contains("youtube."), path.hasPrefix("/@") { return true }
        return false
    }

    // MARK: Parsing

    /// Parse the JSON `yt-dlp --flat-playlist -J <url>` writes to stdout. Nil when not a playlist, so the
    /// caller falls back to the one-URL path; unavailable entries (`null`/no URL) are skipped, not listed.
    public static func parseFlatPlaylist(_ text: String) -> PlaylistExpansion? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parseFlatPlaylist(data)
    }

    /// Data overload — avoids a lossy `Data` → `String` round-trip on titles that
    /// are not valid UTF-8 (yt-dlp escapes them, but extractors have surprised us).
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

    /// Depth-first walk of `entries`, flattening one channel → tab → video level.
    /// `overflowed` latches once the cap is hit so the caller can say so.
    private static func collect(from node: [String: Any], depth: Int,
                                into items: inout [PlaylistItem], overflowed: inout Bool) {
        guard let entries = node["entries"] as? [Any] else { return }
        for entry in entries {
            guard items.count < cap else { overflowed = true; return }
            guard let entry = entry as? [String: Any] else { continue }   // null = unavailable
            if entry["entries"] is [Any] {
                guard depth + 1 < maxNestingDepth else { overflowed = true; continue }
                collect(from: entry, depth: depth + 1, into: &items, overflowed: &overflowed)
                continue
            }
            // `webpage_url` is the canonical page; `url` is what --flat-playlist
            // fills in. Either is downloadable, neither is guaranteed present.
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

    /// yt-dlp writes durations as a JSON number that may be integral or
    /// fractional depending on the extractor; both mean seconds.
    private static func duration(from value: Any?) -> Int? {
        if let n = value as? Int { return n > 0 ? n : nil }
        if let d = value as? Double, d > 0 { return Int(d.rounded()) }
        return nil
    }

    /// Parse `yt-dlp --flat-playlist --print "%(id)s\t%(title)s\t%(url)s\t%(duration)s"`. Exists because
    /// `-J` buffers the WHOLE listing (long silent wait) while `--print` streams; missing values are `NA`.
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

// MARK: - yt-dlp format table

/// One selectable rendition from `yt-dlp -F`. Fields mirror that table's columns, not yt-dlp's JSON,
/// because the table is what the user chooses between; unparsable values stay nil rather than guessed.
public struct MediaFormat: Sendable, Hashable, Identifiable {

    /// yt-dlp's format selector (`137`, `bestaudio`, `hls-1080`). This is the
    /// string handed back to `-f`, so it must survive parsing verbatim.
    public let id: String
    public var ext: String
    /// As printed: `1920x1080`, `audio only`, `48x27`.
    public var resolution: String
    public var height: Int?
    public var fps: Int?
    public var fileSizeBytes: Int64?
    /// True when yt-dlp prefixed the size with `~` (estimated from the bitrate).
    public var isApproximateSize: Bool
    public var vcodec: String?
    public var acodec: String?
    /// The MORE INFO tail (`1080p`, `low, m4a_dash`, `Default`).
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

    /// ONE file, no ffmpeg merge — the picker defaults to these: a video-only format looks like the
    /// obvious "1080p" choice but yields a silent file unless muxed with a separate audio stream.
    public var isSelfContained: Bool { hasVideo && hasAudio }

    /// `1080p60`, `720p`, `audio` — the short label a person scans for.
    public var qualityLabel: String {
        guard let height else { return isAudioOnly ? "audio" : resolution }
        let fpsSuffix = (fps ?? 0) > 30 ? "\(fps!)" : ""
        return "\(height)p\(fpsSuffix)"
    }
}

/// Parser for the human-readable `yt-dlp -F` table (over `--dump-json`: the exact list the user sees, one
/// cheap pass). Fragile, so it DEGRADES rather than fails — an unrecognised row is skipped, never guessed.
public enum MediaFormatTable {

    /// Parse a whole `-F` capture, newest layout (pipe-separated columns) or the
    /// legacy youtube-dl layout, in the order yt-dlp printed them.
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

    /// Rows worth attempting: not a yt-dlp `[info]`/`[youtube]` log line, not the
    /// column header, not the `--- ---` rule, and not blank.
    private static func isFormatRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("-") { return false }
        if trimmed.hasPrefix("ID ") || trimmed.hasPrefix("format code") { return false }
        if trimmed.hasPrefix("WARNING") || trimmed.hasPrefix("ERROR") { return false }
        return true
    }

    // MARK: Modern layout
    // `|` separators are the only reliable landmarks (every other column can be blank); segment first.

    private static func parseModernRow(_ line: String) -> MediaFormat? {
        // "audio only" / "video only" are two-word cell values; fusing them keeps
        // whitespace tokenisation honest.
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

        // FPS and CH are both bare ints and either may be blank: the first number after RESOLUTION is a
        // frame rate only when there is a picture — otherwise it is an audio-only row's channel count.
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

    // MARK: Legacy layout
    // Space-separated `format code / ext / resolution / note`, still printed by youtube-dl and old yt-dlp.

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

    // MARK: Token helpers

    private static func tokens(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func unfuse(_ token: String) -> String {
        token.replacingOccurrences(of: "\u{2060}", with: " ")
    }

    /// Fused `audio only`/`video only` cell marker; nil `kind` matches either. Prefix-compared because
    /// the legacy layout runs these into the note as `video only,` with trailing punctuation.
    private static func isMarker(_ token: String, _ kind: String?) -> Bool {
        guard let kind else {
            return token.hasPrefix("audio\u{2060}only") || token.hasPrefix("video\u{2060}only")
        }
        return token.hasPrefix("\(kind)\u{2060}only")
    }

    /// `1920x1080` → 1080. Anything else (including `audio only`) → nil.
    private static func height(fromResolution token: String) -> Int? {
        let parts = token.lowercased().split(separator: "x")
        guard parts.count == 2, let h = Int(parts[1]) else { return nil }
        return h
    }

    /// Codec cells always carry a profile dot (`avc1.640028`, `mp4a.40.2`) or are
    /// one of the handful of dotless names ffmpeg/yt-dlp print bare.
    private static let dotlessCodecs: Set<String> = [
        "opus", "vorbis", "flac", "mp3", "aac", "vp8", "vp9", "ec-3", "ac-3", "none",
    ]

    private static func isCodecToken(_ token: String) -> Bool {
        if dotlessCodecs.contains(token.lowercased()) { return true }
        guard token.contains("."), let first = token.first else { return false }
        return first.isLetter && byteCount(token) == nil
    }

    /// `1955k`, `~49k`, `128.5k` — a bitrate cell, not something to show as a note.
    private static func isBitrateToken(_ token: String) -> Bool {
        let body = token.hasPrefix("~") ? String(token.dropFirst()) : token
        guard body.hasSuffix("k"), body.count > 1 else { return false }
        return Double(body.dropLast()) != nil
    }

    /// `1.29MiB` / `~50.85MiB` / `900KiB` / `123.4MB` → bytes. `iB` suffixes are
    /// binary (1024) and bare `B` suffixes decimal (1000), matching yt-dlp.
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
        // A bare `B` suffix, but never a bare number: an unsuffixed token is a
        // bitrate or a column index, and treating it as bytes would invent sizes.
        if body.hasSuffix("B"), let value = Double(body.dropLast()) { return Int64(value) }
        return nil
    }
}
