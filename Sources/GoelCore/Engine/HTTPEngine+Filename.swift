import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif  // on Linux, `UTType` is provided by LinuxCompat.swift

// MARK: - Filename resolution (Content-Disposition / Content-Type)

/// Pure, side-effect-free `static` helpers turning HTTP response headers into an on-disk filename.
/// Split out of ``HTTPEngine`` so the download driver stays focused on transfer mechanics.
extension HTTPEngine {

    /// Filename from `Content-Disposition`: RFC 5987 `filename*=UTF-8''…` (percent-decoded) wins
    /// over plain `filename="…"`; nil if absent. `sanitizedName` strips paths, so `../x` can't escape.
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        var plain: String?
        for token in header.components(separatedBy: ";") {
            let part = token.trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = String(part.dropFirst("filename*=".count))
                // charset'lang'pct-encoded  ->  take the part after the second quote.
                let encoded = value.range(of: "''").map { String(value[$0.upperBound...]) } ?? value
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded   // extended form wins outright
                }
            } else if lower.hasPrefix("filename=") {
                let value = String(part.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { plain = value }
            }
        }
        return plain
    }

    /// Preferred file extension for a MIME type (e.g. `video/mp4` -> `mp4`),
    /// stripping any `; charset=…` / `; codecs=…` parameters first.
    static func fileExtension(forMIME mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? mime
        guard !base.isEmpty, base != "application/octet-stream" else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }

    /// Better on-disk name once headers are known, or nil if `current` is already best.
    /// `Content-Disposition` wins; else URL-derived name gains a `Content-Type` ext; `sanitizedName` clamps.
    static func refinedName(current: String, suggestedName: String?, contentType: String?) -> String? {
        var name = current
        if let suggested = suggestedName {
            let cleaned = PathSafety.sanitizedName(suggested, fallback: "")
            if !cleaned.isEmpty { name = cleaned }
        }
        if (name as NSString).pathExtension.isEmpty,
           let ext = fileExtension(forMIME: contentType) {
            name += "." + ext
        }
        let final = PathSafety.sanitizedName(name, fallback: current)
        return final == current ? nil : final
    }
}
