import XCTest
import GoelCore
@testable import GoelApp

final class SpeedProfileTextTests: XCTestCase {

    private func profile(down: Int64, up: Int64) -> TrafficProfile {
        var p = TrafficProfile.low
        p.maxDownloadBytesPerSec = down
        p.maxUploadBytesPerSec = up
        return p
    }

    func testSummaryReadsTheRealLimits() {
        let low = TrafficProfile.low
        let expected = "Low — ↓ \(Double(low.maxDownloadBytesPerSec).speedString), "
            + "↑ \(Double(low.maxUploadBytesPerSec).speedString)"
        XCTAssertEqual(SpeedProfileText.summary(low), expected)
    }

    func testAZeroCapReadsUnlimited() {
        let open = profile(down: 0, up: 0)
        XCTAssertEqual(SpeedProfileText.limits(open), "↓ unlimited, ↑ unlimited")
        XCTAssertEqual(SpeedProfileText.spokenLimits(open), "download unlimited, upload unlimited")
    }

    func testPillShowsTheDownloadCapOnlyWhileTheLimitIsOn() {
        let low = profile(down: 2 * 1_048_576, up: 0)
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: false, profile: low), "Speed: Unlimited")
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: true, profile: low),
                       "Low · \(Double(2 * 1_048_576).speedString)")
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: true, profile: profile(down: 0, up: 5)), "Low")
    }

    /// The profile still changes concurrency and seeding with the snail off, so the tooltip must say so
    /// and must not promise a cap that is not applied.
    func testQueueSummaryMarksCapsOffWhileTheLimitIsOff() {
        let low = TrafficProfile.low
        let off = SpeedProfileText.queueSummary(low, limitEnabled: false)
        XCTAssertTrue(off.hasPrefix("Low — up to 2 downloads at once, seed to 1.0×; speed cap ↓ "), off)
        XCTAssertTrue(off.hasSuffix("(off)"), off)
        let on = SpeedProfileText.queueSummary(low, limitEnabled: true)
        XCTAssertFalse(on.contains("(off)"), on)
    }

    func testSpokenQueueSummaryHasNoArrows() {
        let spoken = SpeedProfileText.spokenQueueSummary(.high, limitEnabled: false)
        XCTAssertEqual(spoken, "up to 10 downloads at once, seed to ratio 2.0, speed limit off")
        XCTAssertFalse(spoken.contains("↓"))
    }
}
