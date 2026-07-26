import XCTest
@testable import GoelApp

/// Covers the version comparison behind "Check for Updates".
///
/// Every failure this guards against looks the same to the user: the app says
/// "Up to date" while a newer release sits in the feed. Nothing else in the
/// product notices, because reporting *no* update is indistinguishable from
/// there being none.
final class UpdateCheckerTests: XCTestCase {

    func testOrdersNumericallyNotLexically() {
        // "1.10" sorts before "1.9" as a string. It is not older.
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(UpdateChecker.isNewer("10.0", than: "9.0"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2", than: "1.0.2"))
    }

    func testMissingTrailingComponentsCountAsZero() {
        // "1.1" and "1.1.0" are the same release written two ways.
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.0", than: "1.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
    }

    /// The regression: `Int($0) ?? 0` mapped "3-rc1" to 0, so a v1.0.3-rc1 tag
    /// parsed as [1, 0, 0] and was judged OLDER than the running 1.0.2.
    func testPreReleaseSuffixComparesOnItsNumericPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.3-rc1", than: "1.0.2"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0-beta.1", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2-rc1", than: "1.0.3"))
    }

    /// A component with no leading digit is not a version. The old code read it
    /// as 0 and silently kept comparing.
    func testUnparseableVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("banana", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.x.0", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.0.2"))
    }

    // MARK: check()

    /// `check` is `async` and reaches the network, so only the paths that
    /// short-circuit before the fetch are exercised here — enough to pin the
    /// contract that an unconfigured feed is reported as such rather than as a
    /// failure or as "up to date".
    func testBlankAndNonHTTPSFeedsAreNotConfiguredRatherThanFailed() async {
        var outcome = await UpdateChecker.check(feedURL: "")
        XCTAssertEqual(outcome, .notConfigured)

        outcome = await UpdateChecker.check(feedURL: "   ")
        XCTAssertEqual(outcome, .notConfigured)

        // Plaintext would let the network choose which page the user is offered.
        outcome = await UpdateChecker.check(feedURL: "http://example.test/releases")
        XCTAssertEqual(outcome, .notConfigured)
    }
}
