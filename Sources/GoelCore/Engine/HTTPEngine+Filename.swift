import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif  // on Linux, `UTType` is provided by LinuxCompat.swift

extension HTTPEngine {

    /// RFC 5987 `filename*` wins over plain `filename`; the value is server-supplied, so callers must run it through `sanitizedName` or `../x` escapes.
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        var plain: String?
        for token in header.components(separatedBy: ";") {
            let part = token.trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = String(part.dropFirst("filename*=".count))
                let encoded = value.range(of: "''").map { String(value[$0.upperBound...]) } ?? value
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            } else if lower.hasPrefix("filename=") {
                let value = String(part.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { plain = value }
            }
        }
        return plain
    }

    static func fileExtension(forMIME mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? mime
        guard !base.isEmpty, base != "application/octet-stream" else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }

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
