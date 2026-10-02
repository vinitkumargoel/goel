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

    func testPlainNetworkErrorOffersRetryLater() {
        XCTAssertEqual(recovery(.network("The Internet connection appears to be offline.")),
                       .retryLater(FailureAdvice.Recovery.retryLaterDelay))
    }

    func testBadRequestAndRejectedResumePointHaveHints() {
        XCTAssertNotNil(FailureAdvice.hint(forHTTPStatus: 400))
        XCTAssertTrue(FailureAdvice.hint(forHTTPStatus: 416)!.contains("beginning"))
        XCTAssertNotNil(FailureAdvice.hint(forHTTPStatus: 418), "a generic 4xx still says something")
        XCTAssertNil(FailureAdvice.hint(forHTTPStatus: 302))
    }

    func testUnknownErrorsGetAGenericHint() {
        XCTAssertNotNil(FailureAdvice.hint(for: .unknown("something odd")))
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

    // MARK: - Recovery

    private func recovery(_ error: DownloadError, kind: DownloadKind = .http,
                          hasData: Bool = false) -> FailureAdvice.Recovery? {
        FailureAdvice.recovery(for: error, kind: kind, hasData: hasData)
    }

    func testLoginFailuresOfferCookies() {
        XCTAssertEqual(recovery(.httpStatus(401)), .attachCookies)
        XCTAssertEqual(recovery(.httpStatus(403)), .attachCookies)
        XCTAssertNil(recovery(.httpStatus(403), kind: .ftp), "cookies only ride on HTTP")
    }

    func testMissingFilesOfferANewLink() {
        XCTAssertEqual(recovery(.httpStatus(404)), .updateLink)
        XCTAssertEqual(recovery(.httpStatus(410)), .updateLink)
        XCTAssertNil(recovery(.httpStatus(404), kind: .hls))
    }

    func testProxyLoginOpensProxySettings() {
        XCTAssertEqual(recovery(.httpStatus(407)), .proxySettings)
    }

    func testBusyServersOfferRetryInFiveMinutes() {
        for code in [408, 429, 500, 502, 503, 599] {
            XCTAssertEqual(recovery(.httpStatus(code)), .retryLater(300), "HTTP \(code)")
        }
        XCTAssertEqual(recovery(.timedOut), .retryLater(300))
    }

    func testFullDiskOffersAnotherFolderOnlyWhereThePartialCanMove() {
        XCTAssertEqual(recovery(.diskFull(needed: 10, available: 1)), .changeFolder)
        XCTAssertEqual(recovery(.network("No space left on device")), .changeFolder)
        XCTAssertEqual(recovery(.diskFull(needed: 10, available: 1), kind: .torrent, hasData: false),
                       .changeFolder)
        XCTAssertNil(recovery(.diskFull(needed: 10, available: 1), kind: .torrent, hasData: true))
    }

    func testFailuresThatRetryAlreadyFixesHaveNoSpecialAction() {
        XCTAssertNil(recovery(.httpStatus(418)))
        XCTAssertNil(recovery(.checksumMismatch))
        XCTAssertNil(recovery(.canceled))
    }

    func testTaskRecoveryReadsTheTasksKindAndProgress() {
        var task = DownloadTask(source: .url(URL(string: "https://example.test/a.iso")!),
                                name: "a.iso", saveDirectory: "/tmp", totalBytes: 100,
                                status: .failed(.httpStatus(404)))
        XCTAssertEqual(FailureAdvice.recovery(for: task, error: .httpStatus(404)), .updateLink)
        task.bytesDownloaded = 50
        XCTAssertEqual(FailureAdvice.recovery(for: task, error: .diskFull(needed: 1, available: 0)),
                       .changeFolder)
    }

    func testRecoveryTitlesNameTheAction() {
        XCTAssertEqual(FailureAdvice.Recovery.attachCookies.title, "Attach Cookies…")
        XCTAssertEqual(FailureAdvice.Recovery.updateLink.title, "Update Link…")
        XCTAssertEqual(FailureAdvice.Recovery.changeFolder.title, "Change Folder…")
        XCTAssertTrue(FailureAdvice.Recovery.retryLater(300).title.hasPrefix("Retry in"))
    }

    func testRedactionLeavesPlainLocatorsAlone() {
        let magnet = "magnet:?xt=urn:btih:abc"
        XCTAssertEqual(FailureAdvice.redactedLocator(magnet), magnet)
        XCTAssertEqual(FailureAdvice.redactedLocator("https://example.test/a"), "https://example.test/a")
    }
}
