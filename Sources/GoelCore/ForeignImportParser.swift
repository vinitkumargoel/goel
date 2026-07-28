import Foundation

public enum ForeignImportParser {

    private static let pattern = #"(?:https?|ftps?)://[^\s,"'<>\\)\]}]+|magnet:\?[^\s,"'<>\\)\]}]+"#

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
            while let last = s.last, ",;.".contains(last) { s.removeLast() }
            guard !s.isEmpty, seen.insert(s).inserted else { return }
            out.append(s)
        }
        return out
    }
}
