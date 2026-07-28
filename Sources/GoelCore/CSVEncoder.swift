import Foundation

public enum CSVEncoder {

    /// CSV injection: a cell starting with one of these is evaluated as a formula (tab/CR too — importers strip leading whitespace).
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    public static func field(_ raw: String) -> String {
        // CSV injection: quoting alone fails — sheets strip quotes before evaluating, so prefix a literal apostrophe.
        if let first = raw.first, formulaLeaders.contains(first) {
            return "\"'" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") || raw.contains("\r") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func table(header: [String], _ rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\n")
    }
}
