import XCTest
@testable import GoelCore

final class SFTPFailOpenRemediationTests: XCTestCase {

    func testRetryRefusesADestinationThatCannotBeListed() {
        XCTAssertNil(SFTPOverwritePlan.retryName("download", against: .unavailable),
                     "an unreadable destination must refuse the retry, not overwrite on a guess")
    }

    func testRetryKeepsItsOwnNameWhenStillFree() {
        XCTAssertEqual(SFTPOverwritePlan.retryName("report.pdf", against: .names(["other.pdf"])),
                       "report.pdf")
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: .names([])), "download")
    }

    /// Row A failed and released the name, row B took it and completed: A's retry must not truncate B.
    func testRetryRenamesRatherThanTruncatingAFileThatIsNowSomeoneElses() {
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: .names(["download"])),
                       "download (1)")
        XCTAssertEqual(SFTPOverwritePlan.retryName("download",
                                                   against: .names(["download", "download (1)"])),
                       "download (2)")
        XCTAssertEqual(SFTPOverwritePlan.retryName("report.pdf", against: .names(["report.pdf"])),
                       "report (1).pdf")
    }

    func testRetryTreatsAQueuedDestinationAsTaken() {
        // "download" is not on disk; it is reserved by another in-flight row.
        let listing = DirectoryListing.names(["unrelated.txt", "download"])
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: listing), "download (1)")
    }

    /// Pins the collision the retry check exists for: every dotfile sanitizes to the same local name.
    func testEveryDotfileStillSanitizesToTheSameLocalName() {
        XCTAssertEqual(PathSafety.sanitizedName(".bashrc"), "download")
        XCTAssertEqual(PathSafety.sanitizedName(".zshrc"), "download")
    }

    /// `gsb_list` has no Swift seam, so the contract is asserted against the C source text itself.
    func testListingLoopTreatsANegativeReaddirAsAFailureNotAsEndOfDirectory() throws {
        let bridge = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SSHBridge/ssh_bridge.c")
        let source = try String(contentsOf: bridge, encoding: .utf8)
        guard let start = source.range(of: "GSBResult gsb_list(") else {
            return XCTFail("gsb_list is no longer in ssh_bridge.c")
        }
        let rest = source[start.upperBound...]
        guard let next = rest.range(of: "\nGSBResult ") else {
            return XCTFail("could not find the end of gsb_list")
        }
        let listBody = rest[rest.startIndex..<next.lowerBound]

        XCTAssertFalse(listBody.contains("&attrs)) > 0)"),
                       "exiting the readdir loop on `> 0` folds a read failure into EOF")
        XCTAssertTrue(listBody.contains("&attrs)) != 0)"),
                      "the loop must distinguish EOF (0) from a failure (negative)")
        XCTAssertTrue(listBody.contains("if (n < 0)"),
                      "a negative readdir return must be handled explicitly")
        XCTAssertTrue(listBody.contains("GSB_ERR_IO"),
                      "a truncated listing must be reported as an error, not as GSB_OK")
    }

    func testAFailedListingStillSendsNothing() {
        XCTAssertNil(SFTPOverwritePlan.split(names: ["report.pdf"], against: .unavailable),
                     "a listing that could not be completed must not authorise any write")
    }
}
