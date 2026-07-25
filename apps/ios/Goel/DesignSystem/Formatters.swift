import Foundation

/// Centralised, pure formatting for every number the UI shows.
///
/// The exact strings here are the ones drawn in `visual.html` — `5.73 GB`, `412.3 MB`,
/// `48.2 MB/s`, `44s left`, `63%`, `3:42`, `−37:18`. One implementation, used everywhere,
/// so two surfaces can never disagree.
///
/// Everything is a pure `static func` over value types: no shared mutable state, no cached
/// `Formatter` instances (those are reference types and not `Sendable`). Numeric assembly uses
/// `String(format:)`, which is locale-independent, so the decimal separator is always `.` and
/// the output is byte-identical to the mockup.
///
/// **Every non-finite input is guarded.** The desktop engine has a documented history of
/// emitting `inf` speeds; none of them may reach a view.
public enum Fmt {

    // MARK: - Constants

    /// Em dash (U+2014) — the "unknown value" placeholder used throughout the mockup.
    public static let placeholder = "—"

    /// Minus sign (U+2212), *not* a hyphen. Used by ``remaining(_:)``.
    public static let minusSign = "−"

    /// Base-10 units, matching `ByteCountFormatter.CountStyle.file` and the mockup.
    private static let unitNames = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    /// Compact unit names for rates, so a slow transfer reads `812 KB/s` and not `812 bytes/s`.
    private static let rateUnitNames = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Anything past this is a bug upstream, not a duration. Also keeps `Int(_:)` from trapping.
    private static let maxSeconds: TimeInterval = 100 * 365 * 24 * 3600

    // MARK: - Bytes

    /// Byte count in base-10 units, at the mockup's precision.
    ///
    /// Two decimals below a mantissa of 10, one decimal above, trailing zeros trimmed:
    /// `5.73 GB`, `3.61 GB`, `412.3 MB`, `1.4 GB`, `18 GB`, `512 bytes`.
    public static func bytes(_ n: Int64) -> String {
        let scaled = scale(Double(max(n, 0)), maxDecimals: 2)
        return "\(mantissaString(scaled)) \(unitNames[scaled.unit])"
    }

    /// Byte count with an unknown value: `nil` renders as `—`.
    public static func bytes(_ n: Int64?) -> String {
        guard let n else { return placeholder }
        return bytes(n)
    }

    /// Progress as "received of total", at the queue row's coarser one-decimal precision.
    ///
    /// The unit is shared when both sides land in the same magnitude — `3.6 of 5.7 GB`,
    /// `3.9 of 12.6 GB`, `1.4 of 18 GB` — and repeated otherwise: `412.3 MB of 5.7 GB`.
    /// With no known total, the received count stands alone: `3.6 GB`.
    public static func bytesPair(_ received: Int64, of total: Int64?) -> String {
        let got = scale(Double(max(received, 0)), maxDecimals: 1)

        guard let total, total > 0 else {
            return "\(mantissaString(got)) \(unitNames[got.unit])"
        }

        let all = scale(Double(total), maxDecimals: 1)
        if got.unit == all.unit {
            return "\(mantissaString(got)) of \(mantissaString(all)) \(unitNames[all.unit])"
        }
        return "\(mantissaString(got)) \(unitNames[got.unit]) of \(mantissaString(all)) \(unitNames[all.unit])"
    }

    // MARK: - Speed

    /// Transfer rate: `48.2 MB/s`, `12.4 MB/s`, `812 KB/s`.
    ///
    /// Non-finite (the engine's `inf`) or negative input renders as `—`.
    public static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec >= 0 else { return placeholder }
        let scaled = scale(bytesPerSec, maxDecimals: 1)
        return "\(mantissaString(scaled)) \(rateUnitNames[scaled.unit])/s"
    }

    // MARK: - Time remaining

    /// Compact ETA for list rows: `44s left`, `1m 42s left`, `2h 14m left`.
    ///
    /// `nil`, non-finite, or non-positive input renders as `—`.
    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let total = positiveWholeSeconds(seconds) else { return placeholder }
        if total < 60 { return "\(total)s left" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s left" }
        return "\(total / 3600)h \((total % 3600) / 60)m left"
    }

    /// Long-form ETA for the detail screen and the expanded Dynamic Island:
    /// `44 s remaining`, `1 m 42 s remaining`, `2 h 14 m remaining`.
    ///
    /// `nil`, non-finite, or non-positive input renders as `—`.
    public static func remainingLong(_ seconds: TimeInterval?) -> String {
        guard let total = positiveWholeSeconds(seconds) else { return placeholder }
        if total < 60 { return "\(total) s remaining" }
        if total < 3600 { return "\(total / 60) m \(total % 60) s remaining" }
        return "\(total / 3600) h \((total % 3600) / 60) m remaining"
    }

    // MARK: - Playback clock

    /// Elapsed playback time: `3:42`, `1:02:11`. Hours are omitted below an hour.
    ///
    /// Non-finite input renders as `0:00`; negatives are clamped to zero.
    public static func duration(_ s: TimeInterval) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(min(max(s, 0), maxSeconds).rounded())
        let seconds = total % 60
        let minutes = (total % 3600) / 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Remaining playback time, signed with U+2212 MINUS SIGN: `−37:18`.
    public static func remaining(_ s: TimeInterval) -> String {
        guard s.isFinite else { return minusSign + "0:00" }
        return minusSign + duration(abs(s))
    }

    // MARK: - Percent

    /// Completion as a whole-number percentage: `63%`.
    ///
    /// Clamped to `0...1`; non-finite input renders as `0%`.
    public static func percent(_ fraction: Double) -> String {
        "\(percentValue(fraction))%"
    }

    /// Completion as an `Int` — for accessibility values, ring strokes, and big numerals.
    ///
    /// Clamped to `0...100`; non-finite input returns `0`.
    public static func percentValue(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    // MARK: - Relative dates

    /// Relative recency for Library rows and stale Live Activities:
    /// `Just now`, `2 min ago`, `Today`, `Yesterday`, `2 days ago`, then an absolute short date.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite else { return placeholder }
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return "\(minutes) min ago"
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = max(2, calendar.dateComponents([.day], from: from, to: to).day ?? 2)
        if days < 7 { return "\(days) days ago" }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The compact form the queue and Library rows use — `2m ago`, `3h ago`, `2d ago`.
    /// `visual.html` shows `412.3 MB · SHA-256 verified · 2m ago`, and a row subtitle is too
    /// tight for `2 min ago` once the byte count and the verification badge are in front of it.
    public static func relativeShort(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite else { return placeholder }
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }

        let calendar = Calendar.current
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = max(1, calendar.dateComponents([.day], from: from, to: to).day ?? 1)
        if days < 7 { return "\(days)d ago" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Calendar-day granularity: `Today` · `Yesterday` · `3 days ago` · `14 Jun`.
    ///
    /// The Library lists *files*, not transfers, and a file that landed six minutes ago is not
    /// meaningfully newer than one that landed an hour ago — `2m ago` is transfer-desk precision
    /// on a shelf. `relativeShort` stays for the queue, where the minute is the point.
    public static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        switch days {
        case ..<0: return "Today"
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: - Magnitude scaling

    /// A byte count reduced to a mantissa plus an index into ``unitNames`` / ``rateUnitNames``.
    private struct Scaled {
        var mantissa: Double
        var unit: Int
        var maxDecimals: Int
    }

    /// Reduces a byte count to base-10 magnitude, then re-normalises if rounding pushed the
    /// mantissa to 1000 (so `999_999` reads `1 MB`, never `1000.0 KB`).
    private static func scale(_ value: Double, maxDecimals: Int) -> Scaled {
        guard value.isFinite, value > 0 else {
            return Scaled(mantissa: 0, unit: 0, maxDecimals: maxDecimals)
        }

        var mantissa = value
        var unit = 0
        while mantissa >= 1000, unit < unitNames.count - 1 {
            mantissa /= 1000
            unit += 1
        }

        var scaled = Scaled(mantissa: mantissa, unit: unit, maxDecimals: maxDecimals)
        if rounded(scaled) >= 1000, unit < unitNames.count - 1 {
            scaled.mantissa = mantissa / 1000
            scaled.unit = unit + 1
        }
        return scaled
    }

    /// Decimal places for a mantissa: whole bytes never take one; below 10 takes the finer of
    /// two, above 10 takes one. Mirrors the mockup — `5.73 GB` but `412.3 MB`.
    private static func decimals(for scaled: Scaled) -> Int {
        guard scaled.unit > 0 else { return 0 }
        return scaled.mantissa < 10 ? scaled.maxDecimals : min(scaled.maxDecimals, 1)
    }

    private static func rounded(_ scaled: Scaled) -> Double {
        let factor = pow(10.0, Double(decimals(for: scaled)))
        return (scaled.mantissa * factor).rounded() / factor
    }

    /// Renders the mantissa with trailing zeros (and a bare decimal point) trimmed,
    /// so `1.40` reads `1.4` and `18.0` reads `18`.
    private static func mantissaString(_ scaled: Scaled) -> String {
        var text = String(format: "%.\(decimals(for: scaled))f", rounded(scaled))
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Duration guards

    /// Whole seconds for a positive, finite, in-range interval; `nil` otherwise.
    /// Sub-second remainders round up to `1` so a live ETA never flickers to `0s left`.
    private static func positiveWholeSeconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < maxSeconds else { return nil }
        return max(1, Int(seconds.rounded()))
    }
}
