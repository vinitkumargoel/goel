import XCTest
import GoelCore
@testable import GoelApp

/// Covers the pure presentation helpers on ``DownloadTask`` — type badge, sidebar buckets, context-menu
/// items — where a wrong answer is a visibly wrong row or a missing action, with nothing logged.
final class TaskDisplayTests: XCTestCase {

    private func task(_ name: String,
                      source: DownloadSource? = nil,
                      totalBytes: Int64? = 100,
                      status: DownloadStatus = .queued) -> DownloadTask {
        DownloadTask(
            source: source ?? .url(URL(string: "https://example.test/\(name)")!),
            name: name,
            saveDirectory: "/tmp",
            totalBytes: totalBytes,
            status: status
        )
    }

    // MARK: fileType

    func testMagnetWithoutMetadataIsMagnetUntilItsSizeIsKnown() {
        let pending = task("Season Pack",
                           source: .magnet("magnet:?xt=urn:btih:abc123"),
                           totalBytes: nil)
        XCTAssertEqual(pending.fileType, .magnet)

        // Once the metadata arrives the row stops being an abstract magnet and
        // starts describing what is actually being fetched.
        let resolved = task("Season Pack",
                            source: .magnet("magnet:?xt=urn:btih:abc123"),
                            totalBytes: 4_000_000)
        XCTAssertEqual(resolved.fileType, .video)
    }

    func testExtensionsMapToTheirCategory() {
        XCTAssertEqual(task("ubuntu-24.04.iso").fileType, .iso)
        XCTAssertEqual(task("clip.mkv").fileType, .video)
        XCTAssertEqual(task("holiday.MP4").fileType, .video)     // case-insensitive
        XCTAssertEqual(task("backup.tar.gz").fileType, .archive)
        XCTAssertEqual(task("Tool.dmg").fileType, .archive)
        XCTAssertEqual(task("Installer.pkg").fileType, .app)
        XCTAssertEqual(task("notes.txt").fileType, .doc)
    }

    func testIsoWinsOverAnArchiveExtensionLaterInTheName() {
        // The checks are ordered, and .iso is deliberately first: a disc image
        // named for the archive it was built from is still a disc image.
        XCTAssertEqual(task("release.iso.zip").fileType, .iso)
    }

    func testTorrentWithoutARecognisedExtensionFallsBackToVideo() {
        let t = task("Some.Series.S01", source: .magnet("magnet:?xt=urn:btih:def"), totalBytes: 9_000)
        XCTAssertEqual(t.kind, .torrent)
        XCTAssertEqual(t.fileType, .video)
    }

    // MARK: isMediaFile

    func testIsMediaFileCoversVideoAndAudioButNotDocuments() {
        for name in ["a.mp4", "a.mkv", "a.mov", "a.webm", "a.mp3", "a.flac", "a.opus"] {
            XCTAssertTrue(task(name).isMediaFile, "\(name) should be convertible")
        }
        for name in ["a.txt", "a.zip", "a.iso", "a.pdf", "noextension"] {
            XCTAssertFalse(task(name).isMediaFile, "\(name) should not offer Convert")
        }
    }

    func testIsMediaFileIgnoresCaseAndUsesTheLastExtension() {
        XCTAssertTrue(task("Movie.MP4").isMediaFile)
        XCTAssertTrue(task("archive.mp4.mkv").isMediaFile)
        XCTAssertFalse(task("movie.mkv.txt").isMediaFile)
    }

    // MARK: badges

    func testKindBadgeCoversEveryTransport() {
        XCTAssertEqual(task("a.bin").kindBadge, "HTTP")
        XCTAssertEqual(task("a", source: .magnet("magnet:?xt=urn:btih:abc")).kindBadge, "BT")
        XCTAssertEqual(task("a", source: .hlsStream(URL(string: "https://h/x.m3u8")!)).kindBadge, "HLS")
        XCTAssertEqual(task("a", source: .url(URL(string: "ftp://h/x.bin")!)).kindBadge, "FTP")
        XCTAssertEqual(task("a", source: .url(URL(string: "sftp://h/x.bin")!)).kindBadge, "SFTP")
    }
}
