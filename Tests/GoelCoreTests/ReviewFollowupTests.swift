import XCTest
@testable import GoelCore

/// Locks in the safety-critical pure logic added with the FDM-parity features:
/// the "never silently replace a finished file" change detector, the request-
/// header sanitiser (reserved + header-splitting protection), tag normalisation,
/// and the tag/label union.
final class ReviewFollowupTests: XCTestCase {

    // MARK: remoteResourceChanged — the "err toward NOT touching the file" guarantee

    func testRemoteChangeNeverActsOnUnknownValidators() {
        // Both sides missing → unknown → not changed.
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: nil, newETag: nil, newSize: nil))
        // A zero/absent size is "unknown", not "0 bytes" → not changed.
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 0, newETag: nil, newSize: 100))
        // An empty ETag on either side is not a usable validator → not changed.
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: "", oldSize: nil, newETag: "x", newSize: nil))
    }

    func testRemoteChangePrefersETag() {
        XCTAssertTrue(DownloadManager.remoteResourceChanged(
            oldETag: "v1", oldSize: 100, newETag: "v2", newSize: 100))
        // ETag matches → unchanged even if the reported size differs.
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: "v1", oldSize: 100, newETag: "v1", newSize: 999))
    }

    func testRemoteChangeFallsBackToSize() {
        XCTAssertTrue(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 100, newETag: nil, newSize: 200))
        XCTAssertFalse(DownloadManager.remoteResourceChanged(
            oldETag: nil, oldSize: 100, newETag: nil, newSize: 100))
    }

    // MARK: sanitizedHeaders — reserved + header-splitting protection

    func testSanitizedHeadersDropsReservedControlAndEmpty() {
        let out = DownloadManager.sanitizedHeaders([
            "X-Api-Key": "abc123",
            "Authorization": "Bearer secret",       // reserved
            "Referer": "https://example.com",        // reserved (own field)
            "X-Inject": "ok\r\nEvil-Header: 1",       // CR/LF → header splitting
            "X-Null": "a\u{0}b",                       // NUL
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

    // MARK: normalizeTags / allTags

    func testNormalizeTagsTrimsDedupesOrderStable() {
        XCTAssertEqual(
            DownloadManager.normalizeTags([" Work ", "work", "Urgent", "", "URGENT", "linux"]),
            ["Work", "Urgent", "linux"])
    }

    func testAllTagsUnionsLegacyLabelAndDedups() {
        let task = DownloadTask(
            source: DownloadSource.parse("https://example.com/a.iso")!,
            name: "a.iso", saveDirectory: "/tmp",
            label: "linux", tags: ["Linux", "iso"])   // "linux" dupes "Linux"
        XCTAssertEqual(task.allTags, ["Linux", "iso"])
    }

    func testAllTagsEmptyWhenNoneSet() {
        let task = DownloadTask(
            source: DownloadSource.parse("https://example.com/a.iso")!,
            name: "a.iso", saveDirectory: "/tmp")
        XCTAssertTrue(task.allTags.isEmpty)
    }
}
