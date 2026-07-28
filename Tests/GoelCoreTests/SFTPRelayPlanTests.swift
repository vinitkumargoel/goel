import XCTest
@testable import GoelCore

/// The pure parts of the relay: what a walk may hide and what it must refuse. Guards against a copy
/// that quietly leaves something out and then reports success.
final class SFTPRelayPlanTests: XCTestCase {

    private func plan(skipped: [String]) -> SFTPRelay.TreePlan {
        SFTPRelay.TreePlan(directories: [], files: [], skipped: skipped)
    }

    func testACompletePlanPasses() {
        XCTAssertNoThrow(try SFTPRelay.requireComplete(plan(skipped: [])))
    }

    func testASkippedEntryStopsTheTransfer() {
        XCTAssertThrowsError(try SFTPRelay.requireComplete(plan(skipped: ["/srv/a/b"]))) { error in
            guard let sftp = error as? SFTPError else { return XCTFail("wrong error type") }
            XCTAssertEqual(sftp.kind, .io)
            XCTAssertTrue(sftp.message.contains("/srv/a/b"), sftp.message)
            XCTAssertTrue(sftp.message.contains("nothing was transferred"), sftp.message)
        }
    }

    func testTheMessageNamesOneEntryAndCountsTheRest() {
        XCTAssertThrowsError(try SFTPRelay.requireComplete(
            plan(skipped: ["/srv/x", "/srv/y", "/srv/z"]))) { error in
            let message = (error as? SFTPError)?.message ?? ""
            XCTAssertTrue(message.contains("/srv/x"), message)
            XCTAssertTrue(message.contains("2 more"), message)
            // The other two are counted, not listed — a hostile listing could
            // otherwise turn one alert into a wall of server-supplied text.
            XCTAssertFalse(message.contains("/srv/y"), message)
        }
    }

    func testTheWalkCeilingsAreSaneAndFinite() {
        // These exist because the tree is described entirely by the server; a
        // ceiling that drifted up to something unbounded would defeat the point.
        XCTAssertGreaterThan(SFTPRelay.maxWalkEntries, 10_000)
        XCTAssertLessThanOrEqual(SFTPRelay.maxWalkEntries, 5_000_000)
        XCTAssertGreaterThan(SFTPRelay.maxWalkDepth, 16)
        XCTAssertLessThanOrEqual(SFTPRelay.maxWalkDepth, 1_024)
    }
}
