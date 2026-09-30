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
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: false, profile: low), "Unlimited")
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: true, profile: low),
                       "Low · \(Double(2 * 1_048_576).speedString)")
        XCTAssertEqual(SpeedProfileText.pill(limitEnabled: true, profile: profile(down: 0, up: 5)), "Low")
    }
}
