import Foundation

/// Extracts download locators from text exported by *other* download managers or browsers. Rather than
/// parse each proprietary format, it scans for `http(s)`/`ftp(s)`/`magnet:`; de-duped, first-seen order.
public enum ForeignImportParser {

    /// URLs of a supported scheme, plus magnet links. Stops at whitespace or the
    /// quoting/markup characters that typically bound a URL in JSON/HTML/XML.
    private static let pattern = #"(?:https?|ftps?)://[^\s,"'<>\\)\]}]+|magnet:\?[^\s,"'<>\\)\]}]+"#

    /// Pull every recognised locator out of `text`, de-duplicated, order-stable.
    public static func extractLocators(from text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            var s = ns.substring(with: match.range)
            // Trim trailing punctuation that rode along from surrounding markup.
            while let last = s.last, ",;.".contains(last) { s.removeLast() }
            guard !s.isEmpty, seen.insert(s).inserted else { return }
            out.append(s)
        }
        return out
    }
}
