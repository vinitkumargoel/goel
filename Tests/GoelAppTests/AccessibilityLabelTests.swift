import XCTest
import GoelCore
@testable import GoelApp

/// VoiceOver reads these verbatim, so the exact wording is the contract — including the units,
/// which are spelled out because "MB" is read aloud as letters.
final class AccessibilityLabelTests: XCTestCase {

    func testBytesSpellsOutTheUnitAndRefusesToGuessAtNothing() {
        let cases: [(Int64?, String)] = [
            (nil, "unknown size"),
            (0, "unknown size"),
            (-1, "unknown size"),
            (512, "512 bytes"),
            (1024, "1.0 kilobytes"),
            (1024 * 1024, "1.0 megabytes"),
            (1024 * 1024 * 1024, "1.0 gigabytes"),
            (1024 * 1024 * 1024 * 1024, "1.0 terabytes"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(A11y.bytes(value), expected, "\(String(describing: value))")
        }
    }

    func testEnormousSizesStopAtTerabytesRatherThanRunningOffTheUnitTable() {
        XCTAssertTrue(A11y.bytes(Int64.max).hasSuffix("terabytes"),
                      "the exponent must be clamped to the last unit word we have")
    }

    func testSpeedIsIdleRatherThanZeroPerSecond() {
        XCTAssertEqual(A11y.speed(0), "idle")
        XCTAssertEqual(A11y.speed(-5), "idle")
        XCTAssertEqual(A11y.speed(1024), "1.0 kilobytes per second")
    }

    func testPercentClampsRatherThanAnnouncingImpossibleProgress() {
        XCTAssertEqual(A11y.percent(-0.5), "0 percent")
        XCTAssertEqual(A11y.percent(0), "0 percent")
        XCTAssertEqual(A11y.percent(0.5), "50 percent")
        XCTAssertEqual(A11y.percent(1), "100 percent")
        XCTAssertEqual(A11y.percent(4.2), "100 percent",
                       "segmented overshoot must not announce 420 percent")
    }

    func testETAPicksItsUnitAndAgreesInNumber() {
        let cases: [(TimeInterval?, String?)] = [
            (nil, nil),
            (0, nil),
            (-30, nil),
            (1, "about 1 second remaining"),
            (30, "about 30 seconds remaining"),
            (60, "about 1 minute remaining"),
            (150, "about 3 minutes remaining"),
            (3600, "about 1.0 hours remaining"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(A11y.eta(seconds), expected, "\(String(describing: seconds))")
        }
    }

    func testSentenceDropsWhatIsMissingInsteadOfLeavingGaps() {
        XCTAssertEqual(A11y.sentence("one", nil, "two"), "one, two")
        XCTAssertEqual(A11y.sentence(nil, nil), "")
        XCTAssertEqual(A11y.sentence("only", "", nil), "only",
                       "an empty string is as absent as a nil — no trailing comma")
    }

    private func task(status: DownloadStatus = .queued,
                      source: DownloadSource? = nil,
                      total: Int64? = 1024 * 1024,
                      done: Int64 = 0) -> DownloadTask {
        var t = DownloadTask(
            source: source ?? .url(URL(string: "https://example.test/a.zip")!),
            name: "a.zip", saveDirectory: "/tmp", totalBytes: total, status: status)
        t.bytesDownloaded = done
        return t
    }

    func testKindIsNamedTheWayItIsSpokenNotTheWayItIsSpelled() {
        XCTAssertEqual(task().accessibilityKindName, "HTTP")
        XCTAssertEqual(
            task(source: .magnet("magnet:?xt=urn:btih:ABCDEF0123456789")).accessibilityKindName,
            "BitTorrent")
        XCTAssertEqual(
            task(source: .hlsStream(URL(string: "https://e.test/i.m3u8")!)).accessibilityKindName,
            "HLS stream")
    }

    private let oops = DownloadError.diskFull(needed: 100, available: 10)

    func testStatusNameCarriesTheFailureReason() {
        XCTAssertEqual(task(status: .queued).accessibilityStatusName, "Queued")
        XCTAssertEqual(task(status: .downloading).accessibilityStatusName, "Downloading")
        XCTAssertEqual(task(status: .requestingMetadata).accessibilityStatusName,
                       "Requesting information")
        let failed = task(status: .failed(oops))
        XCTAssertTrue(failed.accessibilityStatusName.hasPrefix("Failed, "))
        XCTAssertTrue(failed.accessibilityStatusName.contains(oops.message),
                      "the reason must be spoken, not just the word Failed")
    }

    func testTheRowActionMatchesWhatTheButtonWillDo() {
        XCTAssertEqual(task(status: .completed).accessibilityStateActionName, "Show in Finder")
        XCTAssertEqual(task(status: .failed(oops)).accessibilityStateActionName, "Retry")
        XCTAssertEqual(task(status: .paused).accessibilityStateActionName, "Resume")
        XCTAssertEqual(task(status: .queued).accessibilityStateActionName, "Resume")
        XCTAssertEqual(task(status: .downloading).accessibilityStateActionName, "Pause")
    }

    func testProgressValueOmitsSpeedSoVoiceOverStopsRepeatingItself() {
        let value = task(status: .downloading, total: 1024 * 1024, done: 512 * 1024)
            .accessibilityProgressValue
        XCTAssertTrue(value.contains("50 percent"), value)
        XCTAssertTrue(value.contains("512.0 kilobytes of 1.0 megabytes"), value)
        XCTAssertFalse(value.contains("per second"),
                       "speed is sampled twice a second — announcing it would never stop")
    }

    func testRowLabelLeadsWithTheNameAndSkipsAnUnknownETA() {
        let label = task(status: .downloading, total: 1024 * 1024).accessibilityRowLabel
        XCTAssertTrue(label.hasPrefix("a.zip, "), label)
        XCTAssertTrue(label.contains("Downloading"), label)
        XCTAssertFalse(label.contains("remaining"),
                       "a stalled task has no ETA, and must not claim one")
    }
}
