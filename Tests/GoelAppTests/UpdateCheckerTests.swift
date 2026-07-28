import XCTest
@testable import GoelApp

final class UpdateCheckerTests: XCTestCase {

    func testOrdersNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(UpdateChecker.isNewer("10.0", than: "9.0"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2", than: "1.0.2"))
    }

    func testMissingTrailingComponentsCountAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.0", than: "1.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
    }

    func testPreReleaseSuffixComparesOnItsNumericPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.3-rc1", than: "1.0.2"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0-beta.1", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2-rc1", than: "1.0.3"))
    }

    func testUnparseableVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("banana", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.x.0", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.0.2"))
    }

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
