import XCTest
import GoelCore
@testable import GoelApp

final class FailureAdviceTests: XCTestCase {

    func testUnauthorizedAndForbiddenSuggestAnExpiredLink() {
        for code in [401, 403] {
            let hint = FailureAdvice.hint(for: .httpStatus(code))
            XCTAssertNotNil(hint)
            XCTAssertTrue(hint!.contains("expired"), "HTTP \(code): \(hint!)")
            XCTAssertTrue(hint!.contains("login"), "HTTP \(code): \(hint!)")
        }
    }

    func testNotFoundAndGoneSayTheFileMoved() {
        for code in [404, 410] {
            XCTAssertTrue(FailureAdvice.hint(for: .httpStatus(code))!.contains("no longer at this address"))
        }
    }

    func testRateLimitAndServerErrorsSayRetryLater() {
        XCTAssertTrue(FailureAdvice.hint(for: .httpStatus(429))!.contains("Wait a few minutes"))
        XCTAssertTrue(FailureAdvice.hint(for: .httpStatus(503))!.contains("Try again later"))
    }

    func testUnmappedStatusHasNoHint() {
        XCTAssertNil(FailureAdvice.hint(for: .httpStatus(418)))
    }

    func testDiskFullSuggestsAnotherFolder() {
        let hint = FailureAdvice.hint(for: .diskFull(needed: 10, available: 1))
        XCTAssertTrue(hint!.contains("choose another folder"))
    }

    /// ENOSPC often arrives as free text through the network or unknown cases.
    func testDiskFullIsRecognisedInsideFreeTextErrors() {
        let expected = FailureAdvice.hint(for: .diskFull(needed: 1, available: 0))
        XCTAssertEqual(FailureAdvice.hint(for: .network("write failed: No space left on device")), expected)
        XCTAssertEqual(FailureAdvice.hint(for: .unknown("ENOSPC")), expected)
    }

    func testPlainNetworkErrorSuggestsCheckingTheConnection() {
        XCTAssertTrue(FailureAdvice.hint(for: .network("The Internet connection appears to be offline."))!
            .contains("internet connection"))
    }

    func testUnknownAndCanceledHaveNoHint() {
        XCTAssertNil(FailureAdvice.hint(for: .unknown("something odd")))
        XCTAssertNil(FailureAdvice.hint(for: .canceled))
    }

    func testDetailsCarryTheFullErrorAndHintButNoInlineCredentials() {
        let task = DownloadTask(
            source: .url(URL(string: "https://alice:secret@example.test/file.iso")!),
            name: "file.iso",
            saveDirectory: "/tmp",
            totalBytes: 100,
            status: .failed(.httpStatus(403)))
        let details = FailureAdvice.details(for: task, error: .httpStatus(403))

        XCTAssertTrue(details.contains("Server returned HTTP 403"))
        XCTAssertTrue(details.contains("Suggestion: The link may have expired"))
        XCTAssertTrue(details.contains("Save path: /tmp/file.iso"))
        XCTAssertTrue(details.contains("example.test/file.iso"))
        XCTAssertFalse(details.contains("secret"))
        XCTAssertFalse(details.contains("alice"))
    }

    func testRedactionLeavesPlainLocatorsAlone() {
        let magnet = "magnet:?xt=urn:btih:abc"
        XCTAssertEqual(FailureAdvice.redactedLocator(magnet), magnet)
        XCTAssertEqual(FailureAdvice.redactedLocator("https://example.test/a"), "https://example.test/a")
    }
}
