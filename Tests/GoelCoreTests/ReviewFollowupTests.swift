import XCTest
@testable import GoelCore

final class ReviewFollowupTests: XCTestCase {

    func testRemoteChangeNeverActsOnUnknownValidators() {
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: nil, newETag: nil, newSize: nil))
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 0, newETag: nil, newSize: 100))
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: "", oldSize: nil, newETag: "x", newSize: nil))
    }

    func testRemoteChangePrefersETag() {
        XCTAssertTrue(DownloadManager.remoteResourceChanged(
            oldETag: "v1", oldSize: 100, newETag: "v2", newSize: 100))
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: "v1", oldSize: 100, newETag: "v1", newSize: 999))
    }

    func testRemoteChangeFallsBackToSize() {
        XCTAssertTrue(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 100, newETag: nil, newSize: 200))
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 100, newETag: nil, newSize: 100))
    }

    func testSanitizedHeadersDropsReservedControlAndEmpty() {
        let out = DownloadManager.sanitizedHeaders([
            "X-Api-Key": "abc123",
            "Authorization": "Bearer secret",
            "Referer": "https://example.com",
            "X-Inject": "ok\r\nEvil-Header: 1",
            "X-Null": "a\u{0}b",
            "   ": "blank-name",
        ])
        XCTAssertEqual(out, ["X-Api-Key": "abc123"])
    }

    func testHasHeaderControlChars() {
        XCTAssertTrue(DownloadManager.hasHeaderControlChars("a\nb"))
        XCTAssertTrue(DownloadManager.hasHeaderControlChars("a\rb"))
        XCTAssertTrue(DownloadManager.hasHeaderControlChars("a\u{0}b"))
        XCTAssertFalse(DownloadManager.hasHeaderControlChars("perfectly normal value"))
    }

    func testNormalizeTagsTrimsDedupesOrderStable() {
        XCTAssertEqual(
            DownloadManager.normalizeTags([" Work ", "work", "Urgent", "", "URGENT", "linux"]),
            ["Work", "Urgent", "linux"])
    }

    func testAllTagsUnionsLegacyLabelAndDedups() {
        let task = DownloadTask(
            source: DownloadSource.parse("https://example.com/a.iso")!,
            name: "a.iso", saveDirectory: "/tmp",
            label: "linux", tags: ["Linux", "iso"])
        XCTAssertEqual(task.allTags, ["Linux", "iso"])
    }

    func testAllTagsEmptyWhenNoneSet() {
        let task = DownloadTask(
            source: DownloadSource.parse("https://example.com/a.iso")!,
            name: "a.iso", saveDirectory: "/tmp")
        XCTAssertTrue(task.allTags.isEmpty)
    }
}
