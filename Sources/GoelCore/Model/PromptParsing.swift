import Foundation

/// Pure `String -> value` parsers for the free text the macOS app collects in `NSAlert` prompts. Split out
/// of `AppViewModel`'s blocking `runModal()` methods so input handling is testable in GoelCore.
public enum PromptParsing {

    /// Expand a batch-rename `template` per name; `#` becomes a running number (1, 2, …). An
    /// extensionless result inherits the original's extension so the file stays openable.
    public static func batchRename(template: String, over names: [String]) -> [String] {
        names.enumerated().map { index, name in
            var candidate = template.replacingOccurrences(of: "#", with: String(index + 1))
            if (candidate as NSString).pathExtension.isEmpty {
                let ext = (name as NSString).pathExtension
                if !ext.isEmpty { candidate += ".\(ext)" }
            }
            return candidate
        }
    }

    /// Parse multi-line `Name: value` headers: split on the first colon, trim, skip colonless/empty
    /// names, later duplicates win. The engine still filters reserved header names downstream.
    public static func requestHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    /// Split a comma-separated tag string into trimmed, non-empty tags. Canonical de-duplication
    /// and casing are applied downstream by `DownloadManager.setTags`.
    public static func tags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
