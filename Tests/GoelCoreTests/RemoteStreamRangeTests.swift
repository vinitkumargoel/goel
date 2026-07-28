import XCTest
@testable import GoelCore

/// `Range:` is untrusted off-the-wire input; a trap in `parseByteRange` kills the daemon uncatchably.
final class RemoteStreamRangeTests: XCTestCase {

    /// `split` drops empty subsequences, so `bytes=` leaves an empty list and index 0 traps.
    func testEmptyRangeSpecReturnsNilInsteadOfTrapping() {
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=", available: 1000))
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=,", available: 1000))
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=,,,", available: 1000))
        XCTAssertNil(RemoteStreamService.parseByteRange("  BYTES=  ", available: 1000))
    }

    func testLeadingEmptyElementFallsThroughToTheFirstRealRange() {
        let parsed = RemoteStreamService.parseByteRange("bytes=,0-99", available: 1000)
        XCTAssertEqual(parsed?.0, 0)
        XCTAssertEqual(parsed?.1, 99)
    }

    func testWellFormedRangesAreUnaffected() {
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=0-99", available: 1000)?.1, 99)
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=200-", available: 1000)?.0, 200)
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=-100", available: 1000)?.0, 900)
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=2000-", available: 1000))
    }
}
