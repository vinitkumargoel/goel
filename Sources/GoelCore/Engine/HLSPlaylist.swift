import Foundation

/// A selectable rendition from a master playlist (`#EXT-X-STREAM-INF`).
public struct HLSVariant: Sendable, Hashable {
    public var url: URL
    public var bandwidth: Int        // bits/sec; 0 when unknown
    public var width: Int?
    public var height: Int?
    public var codecs: String?
}

/// Decryption parameters for a run of segments (`#EXT-X-KEY`).
public struct HLSKey: Sendable, Hashable {
    public enum Method: String, Sendable {
        case none = "NONE"
        case aes128 = "AES-128"
        case sampleAES = "SAMPLE-AES"
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
               mapURL: URL?,
               targetDuration: Double,
               totalDuration: Double)
}

/// A line-oriented parser for the subset of HLS (RFC 8216) needed to download a
/// VOD stream: master variant selection, media segments, AES-128 keys, and the
/// fMP4 init map. Pure and synchronous so it is unit-testable without a network.
public enum HLSParser {

    public static func parse(_ text: String, baseURL: URL) -> HLSPlaylist? {
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
        var mapURL: URL?
        var pendingVariant: (bw: Int, w: Int?, h: Int?, codecs: String?)?
        var pendingDuration: Double?
        var pendingByteRange: HLSByteRange?
        var lastByteRangeEnd = 0  // for `#EXT-X-BYTERANGE` lines that omit the offset

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(after: "#EXT-X-STREAM-INF:", in: line)
                let res = attrs["RESOLUTION"].map(parseResolution)
                pendingVariant = (
                    bw: Int(attrs["BANDWIDTH"] ?? "") ?? Int(attrs["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                    w: res??.0, h: res??.1,
                    codecs: attrs["CODECS"]
                )
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(value(of: line)) ?? 0
                seq = mediaSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(value(of: line)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(attributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: "#EXT-X-MAP:", in: line)
                if let uri = attrs["URI"] { mapURL = resolve(uri, baseURL) }
            } else if line.hasPrefix("#EXTINF:") {
                let field = value(of: line).split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(field) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = parseByteRange(value(of: line), previousEnd: lastByteRangeEnd)
            } else if line.hasPrefix("#") {
                continue   // an unhandled tag/comment
            } else {
                // A URI line: a variant URI (after STREAM-INF) or a segment URI
                // (after EXTINF). A bare URI with neither preceding tag is ignored.
                if let variant = pendingVariant {
                    if let u = resolve(line, baseURL) {
                        variants.append(HLSVariant(url: u, bandwidth: variant.bw,
                                                   width: variant.w, height: variant.h,
                                                   codecs: variant.codecs))
                    }
                    pendingVariant = nil
                } else if let duration = pendingDuration {
                    // Advance `seq` and clear pending state unconditionally — even
                    // when the URI fails to resolve — so a dropped segment can never
                    // desync the running sequence number that AES-128 IV derivation
                    // depends on.
                    if let u = resolve(line, baseURL) {
                        segments.append(HLSSegment(url: u, duration: duration,
                                                   sequence: seq, key: currentKey,
                                                   byteRange: pendingByteRange))
                    }
                    if let br = pendingByteRange { lastByteRangeEnd = br.start + br.length }
                    seq += 1
                    pendingDuration = nil
                    pendingByteRange = nil
                }
            }
        }

        if !variants.isEmpty && segments.isEmpty {
            return .master(variants)
        }
        guard !segments.isEmpty else { return nil }
        let total = segments.reduce(0) { $0 + $1.duration }
        return .media(segments: segments, mapURL: mapURL,
                      targetDuration: targetDuration, totalDuration: total)
    }

    /// Pick the best variant: highest bandwidth at or below `maxHeight` (when
    /// given), else the highest bandwidth overall.
    public static func selectVariant(_ variants: [HLSVariant], maxHeight: Int? = nil) -> HLSVariant? {
        guard !variants.isEmpty else { return nil }
        if let cap = maxHeight {
            let eligible = variants.filter { ($0.height ?? 0) <= cap }
            if let best = eligible.max(by: { $0.bandwidth < $1.bandwidth }) { return best }
        }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })
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
    private static func parseByteRange(_ s: String, previousEnd: Int) -> HLSByteRange? {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard let first = parts.first,
              let length = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let start: Int
        if parts.count == 2, let off = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            start = off
        } else {
            start = previousEnd
        }
        return HLSByteRange(start: start, length: length)
    }

    private static func parseResolution(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    private static func parseKey(_ attrs: [String: String], baseURL: URL) -> HLSKey? {
        let method = HLSKey.Method(rawValue: attrs["METHOD"] ?? "NONE") ?? .none
        if method == .none { return nil }
        let url = attrs["URI"].flatMap { resolve($0, baseURL) }
        let iv = attrs["IV"].flatMap(hexToData)
        return HLSKey(method: method, url: url, iv: iv)
    }

    /// Resolve a possibly-relative URI against the playlist's base URL.
    private static func resolve(_ uri: String, _ baseURL: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        if let abs = URL(string: trimmed), abs.scheme != nil { return abs }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
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
