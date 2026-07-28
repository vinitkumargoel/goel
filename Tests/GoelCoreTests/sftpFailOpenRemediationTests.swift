import XCTest
@testable import GoelCore

/// Regressions for two SFTP paths that bypassed the overwrite guard into a truncating write:
/// `gsb_list` reporting a cut-short listing as `GSB_OK`, and `retrySFTPTransfer` listing nothing at all.
final class SFTPFailOpenRemediationTests: XCTestCase {

    // MARK: The retry collision check

    /// A destination that cannot be listed refuses the retry, same as the first attempt: without a
    /// listing there is no way to tell a free name from one that would destroy an existing file.
    func testRetryRefusesADestinationThatCannotBeListed() {
        XCTAssertNil(SFTPOverwritePlan.retryName("download", against: .unavailable),
                     "an unreadable destination must refuse the retry, not overwrite on a guess")
    }

    /// The name the row already holds is kept when nothing else has taken it —
    /// a retry that renamed every time would litter the folder.
    func testRetryKeepsItsOwnNameWhenStillFree() {
        XCTAssertEqual(SFTPOverwritePlan.retryName("report.pdf", against: .names(["other.pdf"])),
                       "report.pdf")
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: .names([])), "download")
    }

    /// The demonstrated data loss: row A failed and released "download", row B took it and completed,
    /// A is retried. The retry must land on a uniqued sibling rather than truncating B's finished file.
    func testRetryRenamesRatherThanTruncatingAFileThatIsNowSomeoneElses() {
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: .names(["download"])),
                       "download (1)")
        XCTAssertEqual(SFTPOverwritePlan.retryName("download",
                                                   against: .names(["download", "download (1)"])),
                       "download (2)")
        // The extension is preserved, matching the upload side's rename policy.
        XCTAssertEqual(SFTPOverwritePlan.retryName("report.pdf", against: .names(["report.pdf"])),
                       "report (1).pdf")
    }

    /// The caller's reservation set must be able to include names that exist only as queued transfers —
    /// nothing is on disk for those yet, and that is precisely the window the first defect lived in.
    func testRetryTreatsAQueuedDestinationAsTaken() {
        // "download" is not on disk; it is reserved by another in-flight row.
        let listing = DirectoryListing.names(["unrelated.txt", "download"])
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: listing), "download (1)")
    }

    /// Every remote dotfile sanitizes to the same local name, which makes the collision ordinary.
    /// Recorded so a change to `sanitizedName` cannot quietly remove the reason the retry check exists.
    func testEveryDotfileStillSanitizesToTheSameLocalName() {
        XCTAssertEqual(PathSafety.sanitizedName(".bashrc"), "download")
        XCTAssertEqual(PathSafety.sanitizedName(".zshrc"), "download")
    }

    // MARK: The truncated listing

    /// `gsb_list` has no Swift seam, so the contract is asserted against the C source: a negative
    /// `readdir` return is not end-of-directory, and must surface an error. `GSB_OK` + short list = bug.
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

    /// And the layers above it still fail closed on that error: a thrown listing
    /// becomes `.unavailable`, and `.unavailable` sends nothing.
    func testAFailedListingStillSendsNothing() {
        XCTAssertNil(SFTPOverwritePlan.split(names: ["report.pdf"], against: .unavailable),
                     "a listing that could not be completed must not authorise any write")
    }
}
