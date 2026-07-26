import XCTest
@testable import GoelCore

/// Regressions for the two SFTP paths that still reached a truncating write after
/// the overwrite guard was added.
///
/// The guard itself was real — a listing that *threw* became `.unavailable` and
/// refused the batch. What defeated it was two ways of never reaching it:
///
///   * `gsb_list` exited its `readdir` loop on a negative return exactly as it did
///     on the `0` that means end-of-directory, and returned `GSB_OK`. A listing
///     cut short by a socket failure, a protocol error, or a name too long for the
///     buffer was therefore reported as a *complete* one: names past the cut looked
///     free, no overwrite prompt appeared, and the upload opened them with
///     `LIBSSH2_FXF_TRUNC`.
///   * `retrySFTPTransfer` re-ran the stored paths directly, performing no listing
///     at all. A failed download deletes its partial file and its row stops
///     reserving the name, so Retry could truncate a *different*, completed
///     download — and every remote dotfile sanitizes to the same literal
///     "download", which makes the clash the default rather than the exception.
final class SFTPFailOpenRemediationTests: XCTestCase {

    // MARK: The retry collision check

    /// A destination that cannot be listed refuses the retry. This is the same
    /// rule the first attempt follows: without a listing there is no way to tell a
    /// free name from one that would destroy an existing file.
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

    /// The demonstrated data loss, as a decision: row A failed and released
    /// "download", row B took it and completed, and A is retried. The retry must
    /// land on a uniqued sibling rather than truncating B's finished file.
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

    /// The reservation set the caller passes in must be able to include names that
    /// exist only as queued transfers — nothing is on disk for those yet, and that
    /// is precisely the window the first defect lived in.
    func testRetryTreatsAQueuedDestinationAsTaken() {
        // "download" is not on disk; it is reserved by another in-flight row.
        let listing = DirectoryListing.names(["unrelated.txt", "download"])
        XCTAssertEqual(SFTPOverwritePlan.retryName("download", against: listing), "download (1)")
    }

    /// Every remote dotfile sanitizes to the same local name, which is what makes
    /// the collision ordinary. Recorded here so a change to `sanitizedName` cannot
    /// quietly remove the reason the retry check exists.
    func testEveryDotfileStillSanitizesToTheSameLocalName() {
        XCTAssertEqual(PathSafety.sanitizedName(".bashrc"), "download")
        XCTAssertEqual(PathSafety.sanitizedName(".zshrc"), "download")
    }

    // MARK: The truncated listing

    /// `gsb_list` has no Swift seam and needs a live server plus a mid-enumeration
    /// failure to exercise, so the contract is asserted against the C source: the
    /// loop must not treat a negative `readdir` return as end-of-directory, and the
    /// result must carry an error when it happens. A `GSB_OK` with a short list is
    /// the whole defect — everything above it in the stack is correct given an
    /// honest error.
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
