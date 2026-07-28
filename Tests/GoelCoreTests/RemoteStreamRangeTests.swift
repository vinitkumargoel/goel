import XCTest
@testable import GoelCore

/// Regression cover for malformed `Range:` headers on `/stream`: the header is off-the-wire untrusted,
/// and a trap in `parseByteRange` kills the app/daemon uncatchably. Every shape must return a value or nil.
final class RemoteStreamRangeTests: XCTestCase {

    /// `bytes=` with nothing after it — `split` drops empty subsequences, so the
    /// range list is genuinely empty and an index-0 subscript would trap.
    func testEmptyRangeSpecReturnsNilInsteadOfTrapping() {
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=", available: 1000))
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=,", available: 1000))
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=,,,", available: 1000))
        // Whitespace/case normalisation must not reintroduce the empty case.
        XCTAssertNil(RemoteStreamService.parseByteRange("  BYTES=  ", available: 1000))
    }

    /// A leading empty element must not shadow the first *real* range, which is
    /// the one we serve (we don't do multipart responses).
    func testLeadingEmptyElementFallsThroughToTheFirstRealRange() {
        let parsed = RemoteStreamService.parseByteRange("bytes=,0-99", available: 1000)
        XCTAssertEqual(parsed?.0, 0)
        XCTAssertEqual(parsed?.1, 99)
    }

    /// The well-formed shapes still behave exactly as before the guard.
    func testWellFormedRangesAreUnaffected() {
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=0-99", available: 1000)?.1, 99)
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=200-", available: 1000)?.0, 200)
        XCTAssertEqual(RemoteStreamService.parseByteRange("bytes=-100", available: 1000)?.0, 900)
        XCTAssertNil(RemoteStreamService.parseByteRange("bytes=2000-", available: 1000))
    }
}
