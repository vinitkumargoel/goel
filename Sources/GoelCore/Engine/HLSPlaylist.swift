import Foundation

public struct HLSVariant: Sendable, Hashable {
    public var url: URL
    public var bandwidth: Int
    public var height: Int?
    public var codecs: String?
    public var audioGroupID: String? = nil
    /// Audio arrives as its own resource — this variant alone downloads silent.
    public var hasSeparateAudio: Bool = false
}

public struct HLSKey: Sendable, Hashable {
    /// An unrecognised method must be ``unsupported``, never ``none``, or ciphertext is written as success.
    public enum Method: Sendable, Hashable {
        case none
        case aes128
        case unsupported(String)

        public init(playlistValue: String) {
            switch playlistValue.trimmingCharacters(in: .whitespaces).uppercased() {
            case "NONE":    self = .none
            case "AES-128": self = .aes128
            default:        self = .unsupported(playlistValue)
            }
        }
    }
    public var method: Method
    public var url: URL?
    public var iv: Data?
}

public struct HLSByteRange: Sendable, Hashable {
    public var start: Int
    public var length: Int
}

public struct HLSInitMap: Sendable, Hashable {
    public var url: URL
    public var byteRange: HLSByteRange? = nil
    public var key: HLSKey? = nil
}

public struct HLSSegment: Sendable, Hashable {
    public var url: URL
    public var duration: Double
    public var sequence: Int
    public var key: HLSKey?
    public var byteRange: HLSByteRange? = nil
}

public enum HLSPlaylist: Sendable {
    case master([HLSVariant])
    case media(segments: [HLSSegment],
               map: HLSInitMap?,
               targetDuration: Double,
               totalDuration: Double)
}

enum HLSParser {

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist? {
        // A leading UTF-8 BOM would fail the `#EXTM3U` check on a valid Windows-authored playlist.
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // RFC 8216 §4.3.1.1 requires `#EXTM3U`; it also rejects an error page or redirect body.
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
        var lastByteRangeEnd = 0
        var separateAudioGroups: Set<String> = []

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
                // Reject, don't clamp: `seq` increments per segment (so `Int.max` traps) and derives the AES-128 IV.
                guard let n = Int(value(of: line)), n >= 0, n <= maxMediaSequence else { return nil }
                mediaSequence = n
                seq = mediaSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(value(of: line)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(attributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: "#EXT-X-MAP:", in: line)
                // A nil `map` switches the engine to MPEG-TS remux: an unplayable file reported as success.
                guard let uri = attrs["URI"], let u = resolve(uri, baseURL) else { return nil }
                // In CMAF the init header is a slice of the fragments' own file; losing the range fetches it all.
                var range: HLSByteRange?
                if let raw = attrs["BYTERANGE"] {
                    guard let parsed = parseByteRange(raw, previousEnd: lastByteRangeEnd) else { return nil }
                    range = parsed
                }
                // A map's key is the most recent *preceding* one, not the first segment's (RFC 8216 §4.3.2.5).
                map = HLSInitMap(url: u, byteRange: range, key: currentKey)
                // Seeds the implicit-offset chain; without it a first offset-less range re-reads the header.
                if let range, let mapEnd = end(of: range) { lastByteRangeEnd = mapEnd }
            } else if line.hasPrefix("#EXTINF:") {
                let field = value(of: line).split(separator: ",").first.map(String.init) ?? ""
                // `Double("inf"/"nan"/"1e400")` all parse, and the total is later converted to `Int64` — which traps.
                let parsed = Double(field) ?? 0
                pendingDuration = (parsed.isFinite && parsed >= 0 && parsed <= maxSegmentDuration) ? parsed : 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                // An unparsed range means an unranged fetch of the whole shared resource, so fail instead.
                guard let range = parseByteRange(value(of: line), previousEnd: lastByteRangeEnd) else { return nil }
                pendingByteRange = range
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                // Only a rendition with its own `URI` is a separate track (RFC 8216 §4.3.4.1); the rest are muxed.
                let attrs = attributes(after: "#EXT-X-MEDIA:", in: line)
                if attrs["TYPE"]?.uppercased() == "AUDIO", attrs["URI"] != nil,
                   let group = attrs["GROUP-ID"] {
                    separateAudioGroups.insert(group)
                }
            } else if line.hasPrefix("#") {
                continue
            } else {
                if let variant = pendingVariant {
                    // Skipped rather than fatal: one unusable rendition still leaves the others.
                    if let u = resolve(line, baseURL) {
                        variants.append(HLSVariant(url: u, bandwidth: variant.bw,
                                                   height: variant.h,
                                                   codecs: variant.codecs,
                                                   audioGroupID: variant.audio))
                    }
                    pendingVariant = nil
                } else if let duration = pendingDuration {
                    // Fatal: skipping a segment would report a short file as success and desync the IV sequence.
                    guard let u = resolve(line, baseURL) else { return nil }
                    segments.append(HLSSegment(url: u, duration: duration,
                                               sequence: seq, key: currentKey,
                                               byteRange: pendingByteRange))
                    if let br = pendingByteRange, let brEnd = end(of: br) { lastByteRangeEnd = brEnd }
                    // Overflow-safe only because `maxMediaSequence` bounds the start.
                    seq += 1
                    pendingDuration = nil
                    pendingByteRange = nil
                }
            }
        }

        if !variants.isEmpty && segments.isEmpty {
            // `#EXT-X-MEDIA` may follow the variants referencing it, so resolve the flag only now.
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

    static func selectVariant(_ variants: [HLSVariant], maxHeight: Int? = nil) -> HLSVariant? {
        guard !variants.isEmpty else { return nil }
        if let cap = maxHeight {
            let eligible = variants.filter { ($0.height ?? 0) <= cap }
            if let best = eligible.max(by: { $0.bandwidth < $1.bandwidth }) { return best }
        }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })
    }

    /// A live playlist declares neither tag (RFC 8216 §4.3.3.4/§4.3.3.5) — the engine refuses rather than truncate.
    static func isFinished(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            return line.hasPrefix("#EXT-X-ENDLIST") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD")
        }
    }

    static func declaresAudioCodec(_ codecs: String?) -> Bool {
        guard let codecs else { return false }
        let audioPrefixes = ["mp4a", "ac-3", "ec-3", "ac-4", "opus", "flac", "alac", "dtsc", "dtse"]
        return codecs.split(separator: ",").contains { entry in
            let name = entry.trimmingCharacters(in: .whitespaces).lowercased()
            return audioPrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// 1 PiB: bounding both range fields keeps the running-offset arithmetic overflow-free on network bytes.
    private static let maxByteRangeBound = 1 << 50

    /// Bounded for the same reason — the sequence number rises once per segment.
    private static let maxMediaSequence = 1 << 50

    private static let maxSegmentDuration = 86_400.0

    private static func end(of range: HLSByteRange) -> Int? {
        let (sum, overflow) = range.start.addingReportingOverflow(range.length)
        return overflow ? nil : sum
    }

    private static func value(of line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }

    /// An omitted offset continues from the previous end (RFC 8216 §4.3.2.2); both fields must stay bounded.
    private static func parseByteRange(_ s: String, previousEnd: Int) -> HLSByteRange? {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard let first = parts.first,
              let length = Int(first.trimmingCharacters(in: .whitespaces)),
              length > 0, length <= maxByteRangeBound else { return nil }
        let start: Int
        if parts.count == 2 {
            // Must not fall back to the running offset: that addresses a slice nobody asked for.
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
        // A non-"identity" `KEYFORMAT` is DRM: the URI is a licence endpoint, not 16 bytes of key material.
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

    /// Playlists are untrusted: an absolute `file:`/loopback/`169.254.169.254` URI must stay refused (SSRF).
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
