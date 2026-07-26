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
    /// The encryption a `#EXT-X-KEY` declares. Anything this downloader can't
    /// actually decrypt is carried as ``unsupported`` rather than folded into
    /// ``none``: treating an unrecognised method as "unencrypted" writes
    /// ciphertext to disk and reports the download as finished.
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

/// The fMP4 initialisation segment (`#EXT-X-MAP`): the resource carrying the
/// movie header, plus the optional `BYTERANGE` sub-range that single-file/CMAF
/// packaging uses to place that header inside the *same* resource as the media
/// fragments. The range has to travel with the URI: without it a downloader
/// issues an unranged GET and pulls the whole (often multi-hundred-MB) file down
/// as the "init segment", then concatenates it in front of the fragments.
public struct HLSInitMap: Sendable, Hashable {
    public var url: URL
    public var byteRange: HLSByteRange? = nil  // nil = the whole resource is the init segment
    /// The key in force where the `#EXT-X-MAP` appeared (RFC 8216 §4.3.2.5: the
    /// most recent *preceding* `#EXT-X-KEY`), which is not necessarily the key
    /// the first media segment uses — and is nil when the map precedes any key,
    /// i.e. the init header is plaintext.
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

/// A line-oriented parser for the subset of HLS (RFC 8216) needed to download a
/// VOD stream: master variant selection, media segments, AES-128 keys, and the
/// fMP4 init map. Pure and synchronous so it is unit-testable without a network.
enum HLSParser {

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist? {
        // Strip a leading UTF-8 BOM (U+FEFF). Windows-authored playlists and some
        // packagers emit it; left in place it prepends to the first line and makes
        // the `#EXTM3U` prefix check below fail on an otherwise-valid playlist.
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
                // Bounded at the parse boundary: `seq` is incremented once per
                // segment below, so an unbounded start (`Int.max`) overflows and
                // traps on network bytes. Rejected rather than clamped — the
                // sequence number derives the AES-128 IV, so silently adjusting it
                // would produce output nobody can decrypt.
                guard let n = Int(value(of: line)), n >= 0, n <= maxMediaSequence else { return nil }
                mediaSequence = n
                seq = mediaSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(value(of: line)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(attributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: "#EXT-X-MAP:", in: line)
                // An init map we can't address can't be skipped: leaving `map` nil
                // switches the engine from the fMP4 concat path to the MPEG-TS
                // remux path over fMP4 fragments, i.e. an unplayable file reported
                // as a success. The URI is REQUIRED (RFC 8216 §4.3.2.5) anyway.
                guard let uri = attrs["URI"], let u = resolve(uri, baseURL) else { return nil }
                // Keep the map's own `BYTERANGE` (RFC 8216 §4.3.2.5): in CMAF
                // packaging the init header is a small slice at the head of the
                // very file the fragments live in, so dropping the range turns
                // the init fetch into a download of the entire stream — which is
                // also why a range we can't parse rejects the playlist instead of
                // degrading into "no range".
                var range: HLSByteRange?
                if let raw = attrs["BYTERANGE"] {
                    guard let parsed = parseByteRange(raw, previousEnd: lastByteRangeEnd) else { return nil }
                    range = parsed
                }
                // The key that applies to a map is the most recent one *preceding*
                // it, not the first segment's — carry it so the engine doesn't
                // decrypt a plaintext header, or use the wrong key on an encrypted one.
                map = HLSInitMap(url: u, byteRange: range, key: currentKey)
                // Seed the implicit-offset chain, so a first `#EXT-X-BYTERANGE`
                // that omits `@offset` starts after the init header rather than
                // at byte 0 (where it would re-read the header instead).
                if let range, let mapEnd = end(of: range) { lastByteRangeEnd = mapEnd }
            } else if line.hasPrefix("#EXTINF:") {
                let field = value(of: line).split(separator: ",").first.map(String.init) ?? ""
                // `Double("inf")`, `Double("nan")` and `Double("1e400")` all parse
                // in Swift, and a non-finite duration propagates into the total
                // that the size estimate converts to `Int64` — which traps. The
                // duration only feeds the estimate and the displayed length, so an
                // implausible one is dropped to 0 rather than losing the segment.
                let parsed = Double(field) ?? 0
                pendingDuration = (parsed.isFinite && parsed >= 0 && parsed <= maxSegmentDuration) ? parsed : 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                // Same reasoning as the map's range above: a segment whose range
                // we can't parse would be fetched unranged, pulling the whole
                // shared resource down in place of one segment.
                guard let range = parseByteRange(value(of: line), previousEnd: lastByteRangeEnd) else { return nil }
                pendingByteRange = range
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                // Only a rendition with its OWN `URI` is a separate track; one
                // without a URI is already muxed into the variants naming its group
                // (RFC 8216 §4.3.4.1). Record the groups that aren't, so the engine
                // can refuse a stream whose audio it would otherwise silently drop.
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
                    // One unusable rendition still leaves the others, so a variant
                    // URI that won't resolve is skipped rather than fatal (an empty
                    // variant list is caught by the `return nil` below).
                    if let u = resolve(line, baseURL) {
                        variants.append(HLSVariant(url: u, bandwidth: variant.bw,
                                                   height: variant.h,
                                                   codecs: variant.codecs,
                                                   audioGroupID: variant.audio))
                    }
                    pendingVariant = nil
                } else if let duration = pendingDuration {
                    // A segment URI we can't address means the stream can't be
                    // fetched intact, so reject the whole playlist: dropping the
                    // segment would assemble a file short by exactly that much and
                    // still report success — and would desync the running sequence
                    // number that AES-128 IV derivation depends on.
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
            // `#EXT-X-MEDIA` may appear after the variants that reference it, so
            // the separate-audio flag can only be settled once the whole master
            // playlist has been read.
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

    /// Whether a media playlist declares itself finished: `#EXT-X-ENDLIST`
    /// (RFC 8216 §4.3.3.4) or `#EXT-X-PLAYLIST-TYPE:VOD` (§4.3.3.5). A live
    /// playlist has neither, and downloading one captures nothing but whatever
    /// had been published at that moment — so the engine refuses instead of
    /// writing a truncated file and reporting it complete. Kept as a text-level
    /// helper rather than a fifth associated value on ``HLSPlaylist/media``,
    /// which is pattern-matched across the engine and the tests.
    static func isFinished(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            return line.hasPrefix("#EXT-X-ENDLIST") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD")
        }
    }

    /// Whether a variant's `CODECS` list names an audio codec, i.e. the rendition
    /// carries its own sound. A variant that names an alternate `AUDIO` group but
    /// declares no audio codec of its own has nothing to play without muxing.
    static func declaresAudioCodec(_ codecs: String?) -> Bool {
        guard let codecs else { return false }
        let audioPrefixes = ["mp4a", "ac-3", "ec-3", "ac-4", "opus", "flac", "alac", "dtsc", "dtse"]
        return codecs.split(separator: ",").contains { entry in
            let name = entry.trimmingCharacters(in: .whitespaces).lowercased()
            return audioPrefixes.contains { name.hasPrefix($0) }
        }
    }

    // MARK: Bounds

    /// The largest byte offset or length a `#EXT-X-BYTERANGE` may name (1 PiB).
    /// No real CDN resource comes close, and bounding both fields here is what
    /// makes the running-offset arithmetic provably overflow-free: unbounded
    /// values (`Int.max@Int.max`) make the accumulation trap on network bytes,
    /// before the user has confirmed anything.
    private static let maxByteRangeBound = 1 << 50

    /// The largest `#EXT-X-MEDIA-SEQUENCE` accepted, for the same reason: the
    /// sequence number is incremented once per segment.
    private static let maxMediaSequence = 1 << 50

    /// The longest `#EXTINF` duration accepted (24 h).
    private static let maxSegmentDuration = 86_400.0

    /// The exclusive end offset of a byte range, or nil when the addition would
    /// overflow. ``parseByteRange(_:previousEnd:)`` already bounds both fields,
    /// so this only declines for a range built outside the parser.
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

    /// Parse a `#EXT-X-BYTERANGE` value of the form `<n>[@<o>]`. When the offset
    /// is omitted the sub-range begins right after the previous sub-range's end
    /// (RFC 8216 §4.3.2.2).
    ///
    /// Both fields are bounded here, at the boundary where untrusted playlist text
    /// becomes numbers: every offset the parser accepts is later accumulated and
    /// turned into a `Range` header, and an unbounded one traps on the addition.
    /// A range that doesn't fit — or a malformed offset — is a parse failure, not
    /// something to approximate.
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
        // A `KEYFORMAT` other than "identity" is DRM (FairPlay, Widevine, …): the
        // URI is a licence endpoint, not 16 bytes of key material, so fetching it
        // and using the answer as a key decrypts to noise. Report it as
        // unsupported instead — the segments are still encrypted either way.
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

    /// Resolve a possibly-relative URI against the playlist's base URL, accepting
    /// only http(s).
    ///
    /// A playlist is untrusted network input and `URLSession` happily services a
    /// `file://` data task, so without this an absolute `file:` segment or key URI
    /// would read local bytes and splice them into the output with nothing asked
    /// of the user. Relative URIs inherit the playlist's scheme, so only absolute
    /// URIs are affected.
    ///
    /// The scheme check on its own was not enough. `http` is an allowed scheme, so
    /// a playlist served from anywhere could name
    /// `http://127.0.0.1:8899/api/tasks` as a segment or
    /// `http://169.254.169.254/latest/meta-data/…` as its AES key URI, and the
    /// engine would dutifully fetch both — the playlist body reaching further into
    /// this machine than the address that fetched it ever could.
    /// ``NetworkGuard/isAllowedSubresource(_:of:)`` is the same screen a redirect
    /// hop gets, and for the same reason: it keeps same-host children (which is
    /// every relative URI, and a legitimately local media server) while refusing a
    /// cross-host jump into loopback or the metadata range. Callers treat nil as
    /// fatal for the playlist, so a refused URI fails the download rather than
    /// quietly dropping a segment.
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
