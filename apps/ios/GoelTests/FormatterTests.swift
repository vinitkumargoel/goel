import Foundation
import Testing
@testable import Goel

/// The formatter table. `visual.html` prints these strings literally, so the six values in
/// ``exactStringsFromTheMockup()`` are a contract, not a preference — if one of them changes,
/// the app no longer matches its own design.
///
/// The rest of the suite guards the other half of the job: a formatter is the last thing
/// standing between a `NaN` or an `inf` and a `Text` view that cheerfully renders "inf MB/s".
/// The desktop engine has a documented history of producing infinite speeds; nothing here may
/// pass one through.
@Suite("Formatters")
struct FormatterTests {

    // MARK: - Helpers

    /// Renders a formatter result without depending on its exact return type, so a change of
    /// signature elsewhere fails at the assertion rather than silently at the call site.
    private func text(_ value: Any) -> String { String(describing: value) }

    /// A string is "safe" if a user could read it out loud without noticing a bug.
    private func isSafe(_ s: String) -> Bool {
        let lower = s.lowercased()
        return !s.isEmpty
            && !lower.contains("nan")
            && !lower.contains("inf")
            && !s.contains("e+")
    }

    // MARK: - The contract

    @Test("The six strings the mockup prints literally")
    func exactStringsFromTheMockup() {
        let gigabytes: Int64 = 5_730_000_000
        #expect(Fmt.bytes(gigabytes) == "5.73 GB")
        #expect(Fmt.speed(48_200_000) == "48.2 MB/s")
        #expect(Fmt.eta(44) == "44s left")
        #expect(Fmt.percent(0.63) == "63%")
        #expect(Fmt.duration(222) == "3:42")
        // U+2212 MINUS SIGN, not a hyphen — the mockup's countdown uses the typographic form
        // and it is the only glyph that lines up with tabular figures.
        #expect(Fmt.remaining(2238) == "\u{2212}37:18")
    }

    // MARK: - Byte counts

    @Test("Byte counts are base-10 file style, matching the mockup")
    func byteCounts() {
        // 3.61 GB / 412.3 MB / 1.4 GB all appear in visual.html. Assert the shape rather than
        // every digit, because the unit boundary is what matters here.
        let large: Int64 = 3_610_000_000
        #expect(text(Fmt.bytes(large)).hasSuffix("GB"))
        #expect(text(Fmt.bytes(large)).hasPrefix("3.6"))

        let medium: Int64 = 412_300_000
        #expect(text(Fmt.bytes(medium)).hasSuffix("MB"))
        #expect(text(Fmt.bytes(medium)).hasPrefix("412"))

        #expect(isSafe(text(Fmt.bytes(Int64(0)))))
        #expect(isSafe(text(Fmt.bytes(Int64(1)))))
        #expect(isSafe(text(Fmt.bytes(Int64.max))))
        // A negative count means a bookkeeping bug upstream; it must still print something.
        #expect(isSafe(text(Fmt.bytes(Int64(-1)))))
    }

    @Test("The optional byte overload has a defined answer for nil")
    func optionalByteCount() {
        let unknown: Int64? = nil
        #expect(isSafe(text(Fmt.bytes(unknown))))

        let known: Int64? = 5_730_000_000
        #expect(text(Fmt.bytes(known)) == "5.73 GB")
    }

    @Test("bytesPair prints received against total, and copes with an unknown total")
    func bytesPairs() {
        // The mockup's row subtitle: "3.9 of 12.6 GB".
        let pair = text(Fmt.bytesPair(3_900_000_000, of: 12_600_000_000))
        #expect(isSafe(pair))
        #expect(pair.contains("3.9"))
        #expect(pair.contains("12.6"))

        #expect(isSafe(text(Fmt.bytesPair(1_024, of: nil))))
        #expect(isSafe(text(Fmt.bytesPair(0, of: 0))))
    }

    // MARK: - Speed

    @Test("Speed carries a per-second suffix and never leaks a non-finite value")
    func speeds() {
        #expect(Fmt.speed(48_200_000) == "48.2 MB/s")
        #expect(text(Fmt.speed(12_400_000)).hasSuffix("/s"))

        // The three that have historically reached a view.
        #expect(isSafe(text(Fmt.speed(.infinity))))
        #expect(isSafe(text(Fmt.speed(-.infinity))))
        #expect(isSafe(text(Fmt.speed(.nan))))
        #expect(isSafe(text(Fmt.speed(0))))
        #expect(isSafe(text(Fmt.speed(-1))))
    }

    // MARK: - ETA

    @Test("ETA reads as time left, and has an answer for nil")
    func etas() {
        #expect(Fmt.eta(44) == "44s left")
        #expect(text(Fmt.eta(102)).hasSuffix("left"))

        // Unknown size or zero speed hands this `nil`; it must not crash or print "nil".
        let none = text(Fmt.eta(nil))
        #expect(isSafe(none))
        #expect(!none.lowercased().contains("nil"))
        #expect(!none.lowercased().contains("optional"))

        #expect(isSafe(text(Fmt.eta(0))))
        #expect(isSafe(text(Fmt.eta(.infinity))))
        #expect(isSafe(text(Fmt.eta(.nan))))
        #expect(isSafe(text(Fmt.eta(-5))))
    }

    @Test("remainingLong is the spelled-out form used where there is room for it")
    func remainingLongForm() {
        #expect(isSafe(text(Fmt.remainingLong(2_238))))
        #expect(isSafe(text(Fmt.remainingLong(44))))

        let none = text(Fmt.remainingLong(nil))
        #expect(isSafe(none))
        #expect(!none.lowercased().contains("nil"))
        #expect(isSafe(text(Fmt.remainingLong(.infinity))))
        #expect(isSafe(text(Fmt.remainingLong(.nan))))
    }

    // MARK: - Clock durations

    @Test("duration is a clock reading, remaining is the same reading counted down")
    func clockDurations() {
        #expect(Fmt.duration(222) == "3:42")
        #expect(Fmt.remaining(2238) == "\u{2212}37:18")

        // The countdown is the duration with a minus sign in front of it.
        #expect(text(Fmt.remaining(222)) == "\u{2212}" + text(Fmt.duration(222)))
        // ASCII hyphen-minus is the wrong glyph — it does not align with tabular figures.
        #expect(!text(Fmt.remaining(2238)).contains("-"))

        #expect(isSafe(text(Fmt.duration(0))))
        #expect(isSafe(text(Fmt.duration(59))))
        #expect(isSafe(text(Fmt.duration(3_661))))
        #expect(isSafe(text(Fmt.duration(.infinity))))
        #expect(isSafe(text(Fmt.duration(.nan))))
        #expect(isSafe(text(Fmt.duration(-10))))
        #expect(isSafe(text(Fmt.remaining(.infinity))))
        #expect(isSafe(text(Fmt.remaining(.nan))))
    }

    // MARK: - Percent

    @Test("Percent is clamped, integral, and never NaN")
    func percents() {
        #expect(Fmt.percent(0.63) == "63%")
        #expect(text(Fmt.percent(0)).contains("0"))
        #expect(text(Fmt.percent(1)).contains("100"))

        // Clamping: anything outside 0…1 reads as the nearest end of the range.
        #expect(Fmt.percent(1.7) == Fmt.percent(1))
        #expect(Fmt.percent(-0.5) == Fmt.percent(0))

        #expect(isSafe(text(Fmt.percent(.nan))))
        #expect(isSafe(text(Fmt.percent(.infinity))))
        #expect(isSafe(text(Fmt.percent(-.infinity))))
    }

    @Test("percentValue is the VoiceOver form of the same number")
    func percentValues() {
        // Deliberately type-agnostic: this only pins that the number survives, because
        // CONVENTIONS.md requires progress to reach VoiceOver as a value, not as a colour.
        #expect(text(Fmt.percentValue(0.63)).contains("63"))
        #expect(isSafe(text(Fmt.percentValue(.nan))))
        #expect(isSafe(text(Fmt.percentValue(.infinity))))
        #expect(isSafe(text(Fmt.percentValue(1.7))))
    }

    // MARK: - Relative dates

    @Test("Relative dates are computed against an injected now, so they are testable")
    func relativeDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(isSafe(text(Fmt.relative(now.addingTimeInterval(-60), now: now))))
        #expect(isSafe(text(Fmt.relative(now.addingTimeInterval(-172_800), now: now))))
        // Same instant must still produce something rather than an empty label.
        #expect(isSafe(text(Fmt.relative(now, now: now))))
    }
}
