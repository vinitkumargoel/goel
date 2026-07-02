import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif  // on Linux, `UTType` is provided by LinuxCompat.swift

// MARK: - Filename resolution (Content-Disposition / Content-Type)

/// Pure, testable helpers that turn HTTP response headers into a good on-disk
/// filename. Split out of ``HTTPEngine`` so the download driver stays focused on
/// transfer mechanics; all three are `static` and side-effect free.
extension HTTPEngine {

    /// Parse a filename out of a `Content-Disposition` header. Prefers the
    /// RFC 5987 extended form (`filename*=UTF-8''…`, percent-decoded) and falls
    /// back to the plain `filename="…"`. Returns nil if the header is absent or
    /// carries no usable name. (Path components are stripped later by
    /// `sanitizedName`, so a hostile `filename="../x"` can't escape.)
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

    /// Compute a better on-disk name once response headers are known, or nil if
    /// the current name is already the best we can do. The server-supplied
    /// `Content-Disposition` name wins; otherwise the existing (URL-derived) name
    /// is kept but gains an extension inferred from `Content-Type` when it has
    /// none. The result is sanitized + length-clamped by `sanitizedName`.
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
