import XCTest
@testable import GoelApp

final class InboundDropTests: XCTestCase {

    func testLocalTorrentFilesAreSeparatedFromLinks() {
        let torrent = URL(fileURLWithPath: "/Users/me/Downloads/ubuntu.torrent")
        let upper = URL(fileURLWithPath: "/tmp/Show.TORRENT")
        let http = URL(string: "https://example.test/file.zip")!
        let magnet = URL(string: "magnet:?xt=urn:btih:abc123")!

        let plan = InboundDrop.plan(for: [torrent, http, upper, magnet])

        XCTAssertEqual(plan.torrentFiles, [torrent, upper])
        XCTAssertEqual(plan.links, [http, magnet])
        XCTAssertTrue(plan.unsupportedFiles.isEmpty)
    }

    /// The bug: a Finder drop of a .torrent went to the link parser and failed.
    func testATorrentFileNeverReachesTheLinkParser() {
        let plan = InboundDrop.plan(for: [URL(fileURLWithPath: "/tmp/a.torrent")])
        XCTAssertTrue(plan.links.isEmpty)
        XCTAssertEqual(plan.linkLines, "")
    }

    func testARemoteTorrentURLIsALinkNotALocalFile() {
        let remote = URL(string: "https://releases.example.test/distro.torrent")!
        let plan = InboundDrop.plan(for: [remote])
        XCTAssertEqual(plan.links, [remote])
        XCTAssertTrue(plan.torrentFiles.isEmpty)
    }

    func testOtherLocalFilesAreReportedNotQueued() {
        let zip = URL(fileURLWithPath: "/tmp/archive.zip")
        let folder = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let plan = InboundDrop.plan(for: [zip, folder])

        XCTAssertEqual(plan.unsupportedFiles, [zip, folder])
        XCTAssertTrue(plan.links.isEmpty)
        XCTAssertEqual(InboundDrop.unsupportedMessage(for: [zip]),
                       "Goel° takes links and .torrent files — “archive.zip” is neither")
        XCTAssertEqual(InboundDrop.unsupportedMessage(for: [zip, folder]),
                       "Goel° takes links and .torrent files — 2 of the dropped files are neither")
        XCTAssertNil(InboundDrop.unsupportedMessage(for: []))
    }

    func testLinkLinesJoinOnePerLine() {
        let plan = InboundDrop.plan(for: [URL(string: "https://a.test/1")!, URL(string: "https://a.test/2")!])
        XCTAssertEqual(plan.linkLines, "https://a.test/1\nhttps://a.test/2")
    }

    func testAnEmptyDropIsEmpty() {
        XCTAssertTrue(InboundDrop.plan(for: []).isEmpty)
    }
}
