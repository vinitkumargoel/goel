import XCTest
@testable import GoelApp

final class CreateTorrentValidationTests: XCTestCase {

    func testValidTrackersPassAndBlanksAreIgnored() {
        let text = "udp://tracker.example.org:6969/announce\n\nhttps://t.example.net/announce\n"
        XCTAssertEqual(CreateTorrentValidation.trackerIssues(text), [])
    }

    func testBadTrackerLinesAreReportedWithTheirLineNumber() {
        let text = "udp://tracker.example.org:6969/announce\nnot a url\nftp://x.example.org/a"
        XCTAssertEqual(CreateTorrentValidation.trackerIssues(text).map(\.line), [2, 3])
    }

    func testWebSeedsNeedHttpOrHttps() {
        XCTAssertEqual(CreateTorrentValidation.webSeedIssues("https://a.example.org/f, http://b.example.org/f"), [])
        XCTAssertEqual(CreateTorrentValidation.webSeedIssues("ftp://a.example.org/f").count, 1)
        XCTAssertEqual(CreateTorrentValidation.webSeedIssues("example.org/f").count, 1)
    }

    func testPrivateWithoutTrackersBlocksCreate() {
        XCTAssertTrue(CreateTorrentValidation.privateNeedsTrackers(isPrivate: true, trackers: " \n"))
        XCTAssertNotNil(CreateTorrentValidation.blocker(isPrivate: true, trackers: "", webSeeds: ""))
        XCTAssertFalse(CreateTorrentValidation.privateNeedsTrackers(isPrivate: false, trackers: ""))
        XCTAssertNil(CreateTorrentValidation.blocker(isPrivate: false, trackers: "", webSeeds: ""))
        XCTAssertNil(CreateTorrentValidation.blocker(isPrivate: true, trackers: "udp://t.example.org:1/announce",
                                                      webSeeds: ""))
    }

    func testAnInvalidLineBlocksCreate() {
        XCTAssertNotNil(CreateTorrentValidation.blocker(isPrivate: false, trackers: "oops", webSeeds: ""))
        XCTAssertNotNil(CreateTorrentValidation.blocker(isPrivate: false, trackers: "", webSeeds: "oops"))
    }
}
