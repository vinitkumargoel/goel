import Foundation

/// RFC 4180 CSV field encoding. Extracted from the view model as a pure leaf so
/// the quoting rule is tested at the boundary instead of hiding in an export path.
public enum CSVEncoder {

    /// Quote a single field: wrap it in double-quotes when it contains a
    /// separator, quote, or newline, doubling any embedded quotes.
    public static func field(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Encode a whole table (header + rows) into RFC-4180 text, quoting each cell.
    public static func table(header: [String], _ rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(field).joined(separator: ",") }
            .joined(separator: "\n")
    }
}
