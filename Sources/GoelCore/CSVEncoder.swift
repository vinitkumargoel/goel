import Foundation

/// RFC 4180 CSV field encoding. Extracted from the view model as a pure leaf so
/// the quoting rule is tested at the boundary instead of hiding in an export path.
public enum CSVEncoder {

    /// Leading characters a spreadsheet reads as "this cell is a formula". A
    /// download's name comes from the server's `Content-Disposition` and its
    /// locator is the raw URL, so an exported history opened in Excel / Numbers /
    /// Sheets would otherwise evaluate whatever the far end put there. Tab and
    /// carriage return are included because the importer strips a leading
    /// whitespace character, exposing the formula character behind it.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Quote a single field: wrap it in double-quotes when it contains a
    /// separator, quote, or newline, doubling any embedded quotes. A field that
    /// *starts* with a formula character is additionally neutralised.
    public static func field(_ raw: String) -> String {
        // Neutralise a formula lead-in first: a leading apostrophe is the
        // spreadsheet-standard "treat as text" marker, and force-quoting keeps the
        // result a well-formed RFC-4180 field either way. Quoting alone would not
        // help — the spreadsheet strips the quotes before evaluating.
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
