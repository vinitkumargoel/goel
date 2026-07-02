import Foundation

/// Pure parsers for the free-text the macOS app collects in its `NSAlert`
/// prompts. Extracted out of `AppViewModel`'s modal methods — which build AppKit
/// views and block on `runModal()` — so the actual input handling (running-number
/// rename templates, `Name: value` header parsing, comma-separated tags) lives in
/// the tested GoelCore layer instead of behind a modal in the untested app target.
/// Each function is a pure `String -> value`; the prompt method keeps only the UI.
public enum PromptParsing {

    /// Expand a batch-rename `template` across `names`, one candidate per name.
    /// `#` is replaced by a running number (1, 2, …). When the resulting name has
    /// no extension, the corresponding original name's extension is appended so
    /// the file stays openable.
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

    /// Parse a multi-line `Name: value` header block into a dictionary. Each line
    /// is split on its first colon; the name and value are whitespace-trimmed; a
    /// line with no colon or an empty name is skipped. Later duplicates win. The
    /// engine still filters reserved header names downstream — this only parses.
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

    /// Split a comma-separated tag string into trimmed, non-empty tags. Canonical
    /// de-duplication/casing is applied downstream by `DownloadManager.setTags`;
    /// this is just the text → list step.
    public static func tags(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
