import XCTest
import GoelCore
@testable import GoelApp

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

    /// The Size column says how far along a moving or paused row is, not just the total.
    func testSizeColumnShowsDoneOfTotalWhileUnfinished() {
        var running = task("a.iso", totalBytes: 4_700_000_000, status: .downloading)
        running.bytesDownloaded = 2_910_000_000
        XCTAssertEqual(running.sizeColumnText,
                       L10n.t("%1$@ of %2$@", Int64(2_910_000_000).byteString, Int64(4_700_000_000).byteString))
        var paused = running
        paused.status = .paused
        XCTAssertEqual(paused.sizeColumnText, running.sizeColumnText)

        var done = running
        done.status = .completed
        XCTAssertEqual(done.sizeColumnText, Int64(4_700_000_000).byteString)
        let notStarted = task("b.iso", totalBytes: 1_000, status: .downloading)
        XCTAssertEqual(notStarted.sizeColumnText, Int64(1_000).byteString)
        XCTAssertNil(task("c.iso", totalBytes: nil).sizeColumnText)
    }

    func testMagnetWithoutMetadataIsMagnetUntilItsSizeIsKnown() {
        let pending = task("Season Pack",
                           source: .magnet("magnet:?xt=urn:btih:abc123"),
                           totalBytes: nil)
        XCTAssertEqual(pending.fileType, .magnet)

        let resolved = task("Season Pack",
                            source: .magnet("magnet:?xt=urn:btih:abc123"),
                            totalBytes: 4_000_000)
        XCTAssertEqual(resolved.fileType, .video)
    }

    func testExtensionsMapToTheirCategory() {
        XCTAssertEqual(task("ubuntu-24.04.iso").fileType, .iso)
        XCTAssertEqual(task("clip.mkv").fileType, .video)
        XCTAssertEqual(task("holiday.MP4").fileType, .video)
        XCTAssertEqual(task("backup.tar.gz").fileType, .archive)
        XCTAssertEqual(task("Tool.dmg").fileType, .archive)
        XCTAssertEqual(task("Installer.pkg").fileType, .app)
        XCTAssertEqual(task("notes.txt").fileType, .doc)
    }

    func testIsoWinsOverAnArchiveExtensionLaterInTheName() {
        XCTAssertEqual(task("release.iso.zip").fileType, .iso)
    }

    func testTorrentWithoutARecognisedExtensionFallsBackToVideo() {
        let t = task("Some.Series.S01", source: .magnet("magnet:?xt=urn:btih:def"), totalBytes: 9_000)
        XCTAssertEqual(t.kind, .torrent)
        XCTAssertEqual(t.fileType, .video)
    }

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

    func testKindBadgeCoversEveryTransport() {
        XCTAssertEqual(task("a.bin").kindBadge, "HTTP")
        XCTAssertEqual(task("a", source: .magnet("magnet:?xt=urn:btih:abc")).kindBadge, "BT")
        XCTAssertEqual(task("a", source: .hlsStream(URL(string: "https://h/x.m3u8")!)).kindBadge, "HLS")
        XCTAssertEqual(task("a", source: .url(URL(string: "ftp://h/x.bin")!)).kindBadge, "FTP")
        XCTAssertEqual(task("a", source: .url(URL(string: "sftp://h/x.bin")!)).kindBadge, "SFTP")
    }

    func testACompletedRowWhoseFileIsGoneSaysSo() {
        var t = task("a.zip", status: .completed)
        XCTAssertFalse(t.isFileMissing)
        XCTAssertEqual(t.statusDetailText, L10n.t("Completed"))
        t.fileMissing = true
        XCTAssertTrue(t.isFileMissing)
        XCTAssertEqual(t.statusDetailText, L10n.t("File missing"))
        // Only a finished row can be "missing"; a flag left on a requeued row means nothing.
        t.status = .paused
        XCTAssertFalse(t.isFileMissing)
    }

    // MARK: - Compact status column

    private func seeding(uploaded: Int64, limit: Double?) -> DownloadTask {
        var t = task("pack", source: .magnet("magnet:?xt=urn:btih:abc"), status: .seeding)
        t.bytesDownloaded = 100
        t.bytesUploaded = uploaded
        t.seedRatioLimit = limit
        return t
    }

    func testSeedingIsCompactInTheColumnAndFullInTheTooltip() {
        let t = seeding(uploaded: 184, limit: 2)
        XCTAssertEqual(t.statusCompactText(), L10n.t("Seeding %.2f×", 1.84))
        XCTAssertEqual(t.statusDetailText, L10n.t("Seeding · ratio %1$.2f / %2$.1f", 1.84, 2.0),
                       "the long form stays for the tooltip and VoiceOver")
        XCTAssertLessThan(t.statusCompactText().count, t.statusDetailText.count)
    }

    func testSeedTargetProgressOnlyWhileSeedingTowardATarget() {
        XCTAssertEqual(seeding(uploaded: 100, limit: 2).seedTargetProgress ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(seeding(uploaded: 500, limit: 2).seedTargetProgress, 1, "capped at the target")
        XCTAssertNil(seeding(uploaded: 100, limit: nil).seedTargetProgress, "no target, no bar")
        XCTAssertNil(seeding(uploaded: 100, limit: 0).seedTargetProgress, "0 seeds forever: no target")
        var paused = seeding(uploaded: 100, limit: 2)
        paused.status = .paused
        XCTAssertNil(paused.seedTargetProgress)
    }

    func testDownloadingShowsTimeLeftWithoutRepeatingTheBarsPercent() {
        var t = task("big.bin", totalBytes: 1_000, status: .downloading)
        t.bytesDownloaded = 400
        t.downloadSpeed = 10  // 600 bytes left → 60 s
        XCTAssertEqual(t.statusCompactText(), L10n.t("%@ left", DownloadTask.etaString(60)))
        XCTAssertFalse(t.statusCompactText().contains("%"))
        XCTAssertTrue(t.statusDetailText.contains("40%"), "the tooltip keeps the percent")

        t.downloadSpeed = 0
        XCTAssertEqual(t.statusCompactText(), "40%", "no rate yet: the percent is all there is to say")
    }

    func testQueuedRowSaysItsPlaceInLine() {
        let t = task("a.bin", status: .queued)
        XCTAssertEqual(t.statusCompactText(queueRank: 3), L10n.t("Queued · #%d", 3))
        XCTAssertEqual(t.statusCompactText(), L10n.t("Queued"))
    }

    func testOtherStatesFallBackToTheFullText() {
        let t = task("a.zip", status: .completed)
        XCTAssertEqual(t.statusCompactText(queueRank: 4), t.statusDetailText)
    }
}
