import Foundation

/// A deliberately small `multipart/form-data` reader (RFC 7578) for the portal's uploads.
/// It trusts nothing: every limit is checked while scanning, and any structural surprise is an
/// error rather than a best guess — a guessed part boundary is how one file's bytes end up in another.
enum MultipartFormData {

    struct Part: Equatable {
        var name: String
        var filename: String?
        var contentType: String?
        var body: Data
    }

    enum ParseError: Error, Equatable {
        case notMultipart
        case missingBoundary
        case malformed
        case tooManyParts
        case headersTooLarge
    }

    /// Per-part header block ceiling; a browser sends two short lines.
    static let maxPartHeaderBytes = 8 * 1024

    /// The `boundary` parameter of a `multipart/form-data` Content-Type, or the reason there is none.
    static func boundary(fromContentType header: String?) throws -> String {
        guard let header else { throw ParseError.notMultipart }
        let fields = splitParameters(header)
        guard let media = fields.first?.trimmingCharacters(in: .whitespaces).lowercased(),
              media == "multipart/form-data" else { throw ParseError.notMultipart }
        for field in fields.dropFirst() {
            guard let (key, value) = keyValue(field), key == "boundary" else { continue }
            // RFC 2046 §5.1.1: 1–70 characters, and never ending in a space.
            guard (1...70).contains(value.utf8.count), !value.hasSuffix(" "),
                  value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F })
            else { throw ParseError.missingBoundary }
            return value
        }
        throw ParseError.missingBoundary
    }

    static func parse(_ body: Data, boundary: String, maxParts: Int) throws -> [Part] {
        let dashBoundary = Data(("--" + boundary).utf8)
        let delimiter = Data(("\r\n--" + boundary).utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)

        // The first delimiter may open the body or follow a preamble (which must end in CRLF).
        var cursor: Data.Index
        if body.starts(with: dashBoundary) {
            cursor = body.startIndex + dashBoundary.count
        } else if let first = body.range(of: delimiter) {
            cursor = first.upperBound
        } else {
            throw ParseError.malformed
        }

        var parts: [Part] = []
        while true {
            // After a delimiter: `--` closes the body; otherwise optional padding then CRLF.
            if body[cursor...].starts(with: Data("--".utf8)) { return parts }
            while cursor < body.endIndex, body[cursor] == 0x20 || body[cursor] == 0x09 {
                cursor += 1
            }
            guard body[cursor...].starts(with: crlf) else { throw ParseError.malformed }
            cursor += crlf.count

            guard parts.count < maxParts else { throw ParseError.tooManyParts }

            // An empty header block is legal: the headers end at the very first CRLF.
            let headerData: Data
            if body[cursor...].starts(with: crlf) {
                headerData = Data()
                cursor += crlf.count
            } else {
                let window = body.index(cursor, offsetBy: min(body.endIndex - cursor,
                                                               maxPartHeaderBytes + headerEnd.count))
                guard let end = body.range(of: headerEnd, in: cursor..<window) else {
                    throw window - cursor > maxPartHeaderBytes
                        ? ParseError.headersTooLarge : ParseError.malformed
                }
                headerData = body[cursor..<end.lowerBound]
                cursor = end.upperBound
            }

            guard let next = body.range(of: delimiter, in: cursor..<body.endIndex) else {
                throw ParseError.malformed
            }
            let content = Data(body[cursor..<next.lowerBound])
            cursor = next.upperBound
            parts.append(try part(headers: headerData, body: content))
        }
    }

    private static func part(headers raw: Data, body: Data) throws -> Part {
        guard let text = String(data: raw, encoding: .utf8) else { throw ParseError.malformed }
        var name: String?
        var filename: String?
        var contentType: String?
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "content-disposition":
                let fields = splitParameters(value)
                guard fields.first?.trimmingCharacters(in: .whitespaces).lowercased() == "form-data"
                else { throw ParseError.malformed }
                for field in fields.dropFirst() {
                    guard let (k, v) = keyValue(field) else { continue }
                    if k == "name" { name = v }
                    if k == "filename" { filename = v }
                }
            case "content-type":
                contentType = value
            default:
                continue
            }
        }
        guard let name, !name.isEmpty else { throw ParseError.malformed }
        return Part(name: name, filename: filename, contentType: contentType, body: body)
    }

    /// Splits on `;` outside quoted strings, so `filename="a;b.torrent"` stays one field. Backslash is
    /// literal: browsers percent-encode `"` in names (WHATWG), and a Windows path must survive intact.
    static func splitParameters(_ header: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in header {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";", !inQuotes {
                fields.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        fields.append(current)
        return fields
    }

    /// `key=value` or `key="quoted value"`; the key is lowercased, the value unquoted (not unescaped).
    static func keyValue(_ field: String) -> (String, String)? {
        guard let eq = field.firstIndex(of: "=") else { return nil }
        let key = field[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        let value = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if value.hasPrefix("\"") {
            guard value.count >= 2, value.hasSuffix("\"") else { return nil }
            let inner = String(value.dropFirst().dropLast())
            guard !inner.contains("\"") else { return nil }
            return (key, inner)
        }
        return (key, value)
    }
}
