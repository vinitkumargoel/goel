import XCTest
@testable import GoelCore

/// Direct tests for the response-status classification shared by both byte pumps
/// (`SegmentedTransfer.classify`). This is the acceptance rule that previously
/// drifted between the segmented (206-only) and single-stream (2xx) pumps; the
/// full transfer behaviour is still covered end-to-end by `SegmentedTransferTests`.
final class SegmentedTransferClassifyTests: XCTestCase {
    private typealias T = SegmentedTransfer

    func testRangedPumpAcceptsOnly206() {
        XCTAssertEqual(T.classify(206, ranged: true), .accept)
        XCTAssertEqual(T.classify(200, ranged: true), .reject,
                       "a full 200 body would corrupt segmented offset writes")
        XCTAssertEqual(T.classify(204, ranged: true), .reject)
        XCTAssertEqual(T.classify(416, ranged: true), .reject)
    }

    func testSingleStreamPumpAcceptsAny2xx() {
        for code in [200, 201, 202, 204, 226, 299] {
            XCTAssertEqual(T.classify(code, ranged: false), .accept, "status \(code)")
        }
        XCTAssertEqual(T.classify(300, ranged: false), .reject)
        XCTAssertEqual(T.classify(404, ranged: false), .reject)
    }

    func testRetryableStatusesRetryInEitherMode() {
        for code in [429, 500, 502, 503, 504] {
            XCTAssertEqual(T.classify(code, ranged: true), .retry, "ranged status \(code)")
            XCTAssertEqual(T.classify(code, ranged: false), .retry, "single status \(code)")
        }
    }

    func testNonRetryableServerErrorsReject() {
        XCTAssertEqual(T.classify(501, ranged: false), .reject, "501 is not in the retry set")
        XCTAssertEqual(T.classify(400, ranged: true), .reject)
        XCTAssertEqual(T.classify(403, ranged: false), .reject)
    }
}
