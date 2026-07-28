import Foundation

/// RFC 4180 CSV field encoding. Extracted from the view model as a pure leaf so
/// the quoting rule is tested at the boundary instead of hiding in an export path.
public enum CSVEncoder {

    /// Leading characters a spreadsheet reads as "this cell is a formula". Name (`Content-Disposition`)
    /// and URL are server-supplied; tab and CR count too, as importers strip leading whitespace first.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Quote a field: wrap in double-quotes if it holds a separator, quote, or newline, doubling
    /// embedded quotes. A field *starting* with a formula character is additionally neutralised.
    public static func field(_ raw: String) -> String {
        // Neutralise a formula lead-in: a leading apostrophe is the standard "treat as text" marker
        // and keeps RFC-4180 well-formed. Quoting alone fails — the sheet strips quotes before evaluating.
        if let first = raw.first, formulaLeaders.contains(first) {
            return "\"'" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") || raw.contains("\r") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Encode a whole table (header + rows) into RFC-4180 text, quoting each cell.
    public static func table(header: [String], _ rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\n")
    }
}
