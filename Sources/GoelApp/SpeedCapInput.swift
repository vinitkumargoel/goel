import Foundation
import GoelCore

/// Parses the status bar's "Custom… ↓ ↑" fields. A bare number is MB/s; `k`/`KB`, `m`/`MB`,
/// `g`/`GB` suffixes (optionally with `/s`) override it. Blank, 0 or ∞ mean unlimited (0).
enum SpeedCapInput {
    static func parse(_ raw: String) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty || text == "∞" || text == "0" { return 0 }
        if text.hasSuffix("/s") { text.removeLast(2) }
        if text.hasSuffix("b") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        var multiplier: Double = 1_000_000
        if let last = text.last, "kmg".contains(last) {
            multiplier = last == "k" ? 1_000 : last == "m" ? 1_000_000 : 1_000_000_000
            text.removeLast()
        }
        let number = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let bytes = value * multiplier
        guard bytes < Double(Int64.max / 2) else { return nil }
        return Int64(bytes.rounded())
    }

    /// Prefill text: "5" for 5 MB/s, "" for unlimited.
    static func format(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "" }
        let mb = Double(bytesPerSec) / 1_000_000
        return mb >= 1 && mb.rounded() == mb ? String(Int(mb)) : String(format: "%.0fk", Double(bytesPerSec) / 1_000)
    }
}
