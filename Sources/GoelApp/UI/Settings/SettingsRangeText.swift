import Foundation
import GoelCore

/// Wording for the allowed range of a numeric setting: the row detail ("Allowed: 1–3600.") and the
/// inline note when a typed value had to be pulled in.
enum SettingsRangeText {

    static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    static func text<T: BinaryInteger>(_ range: ClosedRange<T>) -> String {
        "\(range.lowerBound)–\(range.upperBound)"
    }

    static func text(_ range: ClosedRange<Double>) -> String {
        "\(number(range.lowerBound))–\(number(range.upperBound))"
    }

    /// The row's own explanation plus its limits.
    static func detail<T: BinaryInteger>(_ base: String, _ range: ClosedRange<T>) -> String {
        L10n.t("%1$@ Allowed: %2$@.", base, text(range))
    }

    static func detail(_ base: String, _ range: ClosedRange<Double>) -> String {
        L10n.t("%1$@ Allowed: %2$@.", base, text(range))
    }

    static func clampNote<T: BinaryInteger>(typed: String, range: ClosedRange<T>, using: String) -> String {
        L10n.t("%1$@ is outside %2$@. Using %3$@.", typed, text(range), using)
    }

    static func clampNote(typed: String, range: ClosedRange<Double>, using: String) -> String {
        L10n.t("%1$@ is outside %2$@. Using %3$@.", typed, text(range), using)
    }
}
