import Foundation

/// Expands the download-manager batch shorthand in a pasted line:
///
///  - `file[01-20].zip` — a numeric range, zero-padded to the width of its
///    start bound (`[1-20]` counts 1…20 unpadded, `[01-20]` counts 01…20).
///  - `file.{iso,sig}` — a comma alternation.
///
/// Multiple patterns in one line combine as a cartesian product. Expansion is
/// capped so a hostile `[1-999999]` can't wedge the app — an over-cap pattern
/// is returned verbatim (it will then fail URL parsing loudly rather than add
/// a million tasks silently). Magnet links pass through untouched: their
/// parameter soup can legally contain anything.
public enum BatchExpander {

    /// The most tasks a single pasted line may expand into.
    public static let cap = 500

    public static func expand(_ line: String, cap: Int = BatchExpander.cap) -> [String] {
        guard !line.lowercased().hasPrefix("magnet:") else { return [line] }
        var results = [line]
        // Repeatedly expand the first pattern until none remain. Each pass
        // multiplies the list, so guard the cap on every round.
        var expandedAny = true
        while expandedAny {
            expandedAny = false
            var next: [String] = []
            for candidate in results {
                if let variants = expandFirstPattern(in: candidate, cap: cap) {
                    guard next.count + variants.count <= cap else { return [line] }
                    next.append(contentsOf: variants)
                    expandedAny = true
                } else {
                    next.append(candidate)
                }
            }
            results = next
            if results.count > cap { return [line] }
        }
        return results
    }

    /// Expand the leftmost `[N-M]` or `{a,b,…}` pattern, or nil if none exists.
    /// A numeric range wider than `cap` is treated as not-a-pattern (checked
    /// *before* materializing it, so `[1-999999]` never allocates a million rows).
    private static func expandFirstPattern(in line: String, cap: Int) -> [String]? {
        if let range = firstNumericRange(in: line) {
            let inner = String(line[line.index(after: range.lowerBound)..<line.index(before: range.upperBound)])
            let bounds = inner.split(separator: "-")
            let startToken = String(bounds[0]), endToken = String(bounds[1])
            guard let start = Int(startToken), let end = Int(endToken), start <= end,
                  end - start < cap else { return nil }
            // `[01-20]` keeps the leading-zero width; `[1-20]` doesn't pad.
            let width = startToken.hasPrefix("0") ? startToken.count : 0
            return (start...end).map { n in
                let number = width > 0 ? String(format: "%0\(width)d", n) : String(n)
                return line.replacingCharacters(in: range, with: number)
            }
        }
        if let range = firstAlternation(in: line) {
            let inner = String(line[line.index(after: range.lowerBound)..<line.index(before: range.upperBound)])
            let options = inner.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard options.count > 1, options.allSatisfy({ !$0.isEmpty }) else { return nil }
            return options.map { line.replacingCharacters(in: range, with: $0) }
        }
        return nil
    }

    /// The leftmost `[digits-digits]` span. Strictly digits on both sides, so an
    /// IPv6 host literal (`http://[::1]/…`) or a stray bracket never matches.
    private static func firstNumericRange(in line: String) -> Range<String.Index>? {
        line.range(of: #"\[[0-9]+-[0-9]+\]"#, options: .regularExpression)
    }

    /// The leftmost `{a,b,…}` span with at least one comma and no nesting.
    private static func firstAlternation(in line: String) -> Range<String.Index>? {
        line.range(of: #"\{[^{}]*,[^{}]*\}"#, options: .regularExpression)
    }
}
