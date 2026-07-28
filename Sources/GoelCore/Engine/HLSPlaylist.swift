import Foundation

/// A selectable rendition from a master playlist (`#EXT-X-STREAM-INF`).
public struct HLSVariant: Sendable, Hashable {
    public var url: URL
    public var bandwidth: Int        // bits/sec; 0 when unknown
    public var height: Int?
    public var codecs: String?
    /// The `AUDIO` rendition group this variant draws its audio from, when it
    /// names one (`#EXT-X-STREAM-INF:AUDIO="…"`); nil when it names none.
    public var audioGroupID: String? = nil
    /// True when that group delivers audio as its own resource rather than muxed
    /// into this variant, so downloading the variant alone yields a silent video.
    public var hasSeparateAudio: Bool = false
}

/// Decryption parameters for a run of segments (`#EXT-X-KEY`).
public struct HLSKey: Sendable, Hashable {
    /// The encryption a `#EXT-X-KEY` declares. Undecryptable methods become ``unsupported``, never ``none``:
    /// treating an unrecognised method as "unencrypted" writes ciphertext to disk and reports success.
    public enum Method: Sendable, Hashable {
        case none
        case aes128
        /// A method we can't decrypt (SAMPLE-AES, AES-256, DRM…), carrying the
        /// playlist's own spelling of it so the refusal can name it.
        case unsupported(String)

        /// Map a playlist's `METHOD` attribute onto a case, failing closed: only
        /// the two methods the engine implements are recognised.
        public init(playlistValue: String) {
            switch playlistValue.trimmingCharacters(in: .whitespaces).uppercased() {
            case "NONE":    self = .none
            case "AES-128": self = .aes128
            default:        self = .unsupported(playlistValue)
            }
        }
    }
    public var method: Method
    public var url: URL?     // key resource URI (nil for NONE)
    public var iv: Data?     // explicit IV, else derived from the sequence number
}

/// A byte sub-range within a segment's resource (`#EXT-X-BYTERANGE`), used by
/// single-file/CMAF packaging where several segments share one URI.
public struct HLSByteRange: Sendable, Hashable {
    public var start: Int   // first byte offset (inclusive)
    public var length: Int  // number of bytes
}

/// The fMP4 init segment (`#EXT-X-MAP`): the movie-header resource plus the optional `BYTERANGE` that CMAF uses to
/// place it inside the fragments' own resource. The range must travel with the URI, or an unranged GET pulls the whole file.
public struct HLSInitMap: Sendable, Hashable {
    public var url: URL
    public var byteRange: HLSByteRange? = nil  // nil = the whole resource is the init segment
    /// The key in force where the `#EXT-X-MAP` appeared (RFC 8216 §4.3.2.5: most recent *preceding* `#EXT-X-KEY`),
    /// not necessarily the first segment's — nil when the map precedes any key, i.e. a plaintext init header.
    public var key: HLSKey? = nil
}

/// One media segment (`#EXTINF` + its URI).
public struct HLSSegment: Sendable, Hashable {
    public var url: URL
    public var duration: Double
    public var sequence: Int
    public var key: HLSKey?  // nil = unencrypted
    public var byteRange: HLSByteRange? = nil  // nil = fetch the whole resource
}

/// A parsed playlist: either a master (list of variants) or a media playlist
/// (an ordered segment list, plus an optional fMP4 init map).
public enum HLSPlaylist: Sendable {
    case master([HLSVariant])
    case media(segments: [HLSSegment],
               map: HLSInitMap?,
               targetDuration: Double,
               totalDuration: Double)
}

/// Line-oriented parser for the HLS (RFC 8216) subset needed to download a VOD stream: variant selection, media
/// segments, AES-128 keys, fMP4 init map. Pure and synchronous so it is unit-testable without a network.
enum HLSParser {

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist? {
        // Strip a leading UTF-8 BOM (U+FEFF), emitted by Windows-authored playlists and some packagers;
        // left in place it makes the `#EXTM3U` prefix check below fail on an otherwise-valid playlist.
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // RFC 8216 §4.3.1.1: a playlist MUST begin with `#EXTM3U`. Requiring it
        // rejects arbitrary text (an error page, a redirect body) outright.
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }

        var variants: [HLSVariant] = []
        var segments: [HLSSegment] = []
        var targetDuration = 0.0
        var mediaSequence = 0
        var seq = 0
        var currentKey: HLSKey?
        var map: HLSInitMap?
        var pendingVariant: (bw: Int, h: Int?, codecs: String?, audio: String?)?
        var pendingDuration: Double?
        var pendingByteRange: HLSByteRange?
        var lastByteRangeEnd = 0  // for `#EXT-X-BYTERANGE` lines that omit the offset
        var separateAudioGroups: Set<String> = []  // `#EXT-X-MEDIA` groups with their own URI

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(after: "#EXT-X-STREAM-INF:", in: line)
                let res = attrs["RESOLUTION"].map(parseResolution)
                pendingVariant = (
                    bw: Int(attrs["BANDWIDTH"] ?? "") ?? Int(attrs["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                    h: res??.1,
                    codecs: attrs["CODECS"],
                    audio: attrs["AUDIO"]
                )
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                // Bounded at the parse boundary: `seq` increments per segment, so an unbounded start (`Int.max`)
                // traps on network bytes. Rejected not clamped — it derives the AES-128 IV, so adjusting it breaks decryption.
                guard let n = Int(value(of: line)), n >= 0, n <= maxMediaSequence else { return nil }
                mediaSequence = n
                seq = mediaSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(value(of: line)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(attributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: "#EXT-X-MAP:", in: line)
                // An unaddressable init map can't be skipped: a nil `map` switches the engine from fMP4 concat to
                // MPEG-TS remux, i.e. an unplayable file reported as success. URI is REQUIRED (RFC 8216 §4.3.2.5).
                guard let uri = attrs["URI"], let u = resolve(uri, baseURL) else { return nil }
                // Keep the map's own `BYTERANGE` (RFC 8216 §4.3.2.5): in CMAF the init header is a slice at the head
                // of the fragments' own file, so dropping (or failing to parse) the range downloads the whole stream.
                var range: HLSByteRange?
                if let raw = attrs["BYTERANGE"] {
                    guard let parsed = parseByteRange(raw, previousEnd: lastByteRangeEnd) else { return nil }
                    range = parsed
                }
                // The key applying to a map is the most recent one *preceding* it, not the first segment's —
                // carry it so the engine doesn't decrypt a plaintext header or use the wrong key on an encrypted one.
                map = HLSInitMap(url: u, byteRange: range, key: currentKey)
                // Seed the implicit-offset chain, so a first `#EXT-X-BYTERANGE` omitting `@offset` starts
                // after the init header rather than at byte 0 (where it would re-read the header).
                if let range, let mapEnd = end(of: range) { lastByteRangeEnd = mapEnd }
            } else if line.hasPrefix("#EXTINF:") {
                let field = value(of: line).split(separator: ",").first.map(String.init) ?? ""
                // `Double("inf"/"nan"/"1e400")` all parse in Swift, and a non-finite duration propagates into the
                // total the size estimate converts to `Int64` — which traps. Implausible values drop to 0.
                let parsed = Double(field) ?? 0
                pendingDuration = (parsed.isFinite && parsed >= 0 && parsed <= maxSegmentDuration) ? parsed : 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                // Same reasoning as the map's range above: a segment whose range we can't parse would be
                // fetched unranged, pulling the whole shared resource down in place of one segment.
                guard let range = parseByteRange(value(of: line), previousEnd: lastByteRangeEnd) else { return nil }
                pendingByteRange = range
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                // Only a rendition with its OWN `URI` is a separate track; one without is already muxed into the
                // variants naming its group (RFC 8216 §4.3.4.1). Recorded so the engine can refuse dropped audio.
                let attrs = attributes(after: "#EXT-X-MEDIA:", in: line)
                if attrs["TYPE"]?.uppercased() == "AUDIO", attrs["URI"] != nil,
                   let group = attrs["GROUP-ID"] {
                    separateAudioGroups.insert(group)
                }
            } else if line.hasPrefix("#") {
                continue   // an unhandled tag/comment
            } else {
                // A URI line: a variant URI (after STREAM-INF) or a segment URI
                // (after EXTINF). A bare URI with neither preceding tag is ignored.
                if let variant = pendingVariant {
                    // One unusable rendition still leaves the others, so an unresolvable variant URI is
                    // skipped rather than fatal (an empty variant list is caught by the `return nil` below).
                    if let u = resolve(line, baseURL) {
                        variants.append(HLSVariant(url: u, bandwidth: variant.bw,
                                                   height: variant.h,
                                                   codecs: variant.codecs,
                                                   audioGroupID: variant.audio))
                    }
                    pendingVariant = nil
                } else if let duration = pendingDuration {
                    // Reject the whole playlist: dropping an unaddressable segment would assemble a file short
                    // by that much yet report success, and desync the sequence number AES-128 IV derivation needs.
                    guard let u = resolve(line, baseURL) else { return nil }
                    segments.append(HLSSegment(url: u, duration: duration,
                                               sequence: seq, key: currentKey,
                                               byteRange: pendingByteRange))
                    if let br = pendingByteRange, let brEnd = end(of: br) { lastByteRangeEnd = brEnd }
                    // Safe: `seq` starts at or below `maxMediaSequence` and rises
                    // once per segment line, so it can't reach an overflow.
                    seq += 1
                    pendingDuration = nil
                    pendingByteRange = nil
                }
            }
        }

        if !variants.isEmpty && segments.isEmpty {
            // `#EXT-X-MEDIA` may appear after the variants that reference it, so the separate-audio
            // flag can only be settled once the whole master playlist has been read.
            return .master(variants.map { variant in
                var resolved = variant
                resolved.hasSeparateAudio = variant.audioGroupID.map(separateAudioGroups.contains) ?? false
                return resolved
            })
        }
        guard !segments.isEmpty else { return nil }
        let total = segments.reduce(0) { $0 + $1.duration }
        return .media(segments: segments, map: map,
                      targetDuration: targetDuration, totalDuration: total)
    }

    /// Pick the best variant: highest bandwidth at or below `maxHeight` (when
    /// given), else the highest bandwidth overall.
    static func selectVariant(_ variants: [HLSVariant], maxHeight: Int? = nil) -> HLSVariant? {
        guard !variants.isEmpty else { return nil }
        if let cap = maxHeight {
            let eligible = variants.filter { ($0.height ?? 0) <= cap }
            if let best = eligible.max(by: { $0.bandwidth < $1.bandwidth }) { return best }
        }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })
    }

    /// Whether a media playlist declares itself finished: `#EXT-X-ENDLIST` (RFC 8216 §4.3.3.4) or
    /// `#EXT-X-PLAYLIST-TYPE:VOD` (§4.3.3.5). A live playlist has neither; the engine refuses rather than truncate.
    static func isFinished(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            return line.hasPrefix("#EXT-X-ENDLIST") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD")
        }
    }

    /// Whether a variant's `CODECS` list names an audio codec, i.e. it carries its own sound. One that names an
    /// alternate `AUDIO` group but declares no audio codec has nothing to play without muxing.
    static func declaresAudioCodec(_ codecs: String?) -> Bool {
        guard let codecs else { return false }
        let audioPrefixes = ["mp4a", "ac-3", "ec-3", "ac-4", "opus", "flac", "alac", "dtsc", "dtse"]
        return codecs.split(separator: ",").contains { entry in
            let name = entry.trimmingCharacters(in: .whitespaces).lowercased()
            return audioPrefixes.contains { name.hasPrefix($0) }
        }
    }

    // MARK: Bounds

    /// The largest offset or length a `#EXT-X-BYTERANGE` may name (1 PiB). Bounding both fields makes the
    /// running-offset arithmetic provably overflow-free; `Int.max@Int.max` would trap on network bytes.
    private static let maxByteRangeBound = 1 << 50

    /// The largest `#EXT-X-MEDIA-SEQUENCE` accepted, for the same reason: the
    /// sequence number is incremented once per segment.
    private static let maxMediaSequence = 1 << 50

    /// The longest `#EXTINF` duration accepted (24 h).
    private static let maxSegmentDuration = 86_400.0

    /// The exclusive end offset of a byte range, or nil when the addition would overflow.
    /// ``parseByteRange(_:previousEnd:)`` bounds both fields, so this only declines ranges built outside the parser.
    private static func end(of range: HLSByteRange) -> Int? {
        let (sum, overflow) = range.start.addingReportingOverflow(range.length)
        return overflow ? nil : sum
    }

    // MARK: Line helpers

    /// The text after the first `:` in a `#TAG:value` line.
    private static func value(of line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }

    /// Parse `#EXT-X-BYTERANGE` `<n>[@<o>]`; an omitted offset continues from the previous end (RFC 8216 §4.3.2.2).
    /// Both fields are bounded here — offsets are accumulated into a `Range` header and an unbounded one traps.
    private static func parseByteRange(_ s: String, previousEnd: Int) -> HLSByteRange? {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard let first = parts.first,
              let length = Int(first.trimmingCharacters(in: .whitespaces)),
              length > 0, length <= maxByteRangeBound else { return nil }
        let start: Int
        if parts.count == 2 {
            // An unparseable offset must NOT fall back to the running one: that
            // would silently address a slice the playlist never asked for.
            guard let off = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            start = off
        } else {
            start = previousEnd
        }
        guard start >= 0, start <= maxByteRangeBound,
              start + length <= maxByteRangeBound else { return nil }
        return HLSByteRange(start: start, length: length)
    }

    private static func parseResolution(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    private static func parseKey(_ attrs: [String: String], baseURL: URL) -> HLSKey? {
        // A `KEYFORMAT` other than "identity" is DRM (FairPlay, Widevine, …): the URI is a licence endpoint,
        // not 16 bytes of key material, so using the answer as a key decrypts to noise. Report unsupported.
        let format = attrs["KEYFORMAT"] ?? "identity"
        guard format.caseInsensitiveCompare("identity") == .orderedSame else {
            return HLSKey(method: .unsupported("DRM (KEYFORMAT=\(format))"), url: nil, iv: nil)
        }
        let method = HLSKey.Method(playlistValue: attrs["METHOD"] ?? "NONE")
        if method == .none { return nil }
        let url = attrs["URI"].flatMap { resolve($0, baseURL) }
        let iv = attrs["IV"].flatMap(hexToData)
        return HLSKey(method: method, url: url, iv: iv)
    }

    /// Resolve a possibly-relative URI against the playlist's base URL. Playlists are untrusted, so an absolute
    /// `file:`/loopback/`169.254.169.254` URI is refused via ``NetworkGuard/isAllowedSubresource(_:of:)``; nil is fatal.
    private static func resolve(_ uri: String, _ baseURL: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        let resolved: URL?
        if let abs = URL(string: trimmed), abs.scheme != nil {
            resolved = abs
        } else {
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        guard let resolved, NetworkGuard.isAllowedSubresource(resolved, of: baseURL) else { return nil }
        return resolved
    }

    /// Parse an attribute list (`KEY=VALUE,KEY="quoted,value"`) respecting quotes.
    static func attributes(after prefix: String, in line: String) -> [String: String] {
        let body = String(line.dropFirst(prefix.count))
        var result: [String: String] = [:]
        var current = ""
        var fields: [String] = []
        var inQuotes = false
        for ch in body {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) }
            else if ch == ",", !inQuotes { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        if !current.isEmpty { fields.append(current) }
        for field in fields {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            var val = String(field[field.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            result[key] = val
        }
        return result
    }

    /// Decode a `0x…`/`0X…` hex string (e.g. an IV) into bytes.
    static func hexToData(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
