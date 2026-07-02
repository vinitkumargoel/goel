import XCTest
@testable import GoelCore

/// Tests for the feature batch: time-of-day scheduling, transfer statistics,
/// backup pruning, RSS parsing, the export envelope, and model decode
/// compatibility for the new optional fields.
final class NewFeatureTests: XCTestCase {

    // MARK: Download window

    private func settings(start: Int, end: Int, days: [Int] = [1, 2, 3, 4, 5, 6, 7],
                          enabled: Bool = true) -> AppSettings {
        AppSettings(scheduleEnabled: enabled, scheduleStartMinute: start,
                    scheduleEndMinute: end, scheduleDays: days)
    }

    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        // 2026-07-05 is a Sunday (weekday 1); offset to the wanted weekday.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 5 + (weekday - 1)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    func testWindowDisabledIsAlwaysOpen() {
        let s = settings(start: 0, end: 60, enabled: false)
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 2, hour: 15)))
    }

    func testSimpleDaytimeWindow() {
        let s = settings(start: 9 * 60, end: 17 * 60)
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 3, hour: 12)))
        XCTAssertFalse(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 3, hour: 18)))
        XCTAssertFalse(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 3, hour: 8, minute: 59)))
    }

    func testOvernightWindowWraps() {
        let s = settings(start: 22 * 60, end: 7 * 60)
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 4, hour: 23)))
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 4, hour: 3)))
        XCTAssertFalse(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 4, hour: 12)))
    }

    func testDegenerateWindowIsAlwaysOpen() {
        let s = settings(start: 600, end: 600)
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: s, date: date(weekday: 5, hour: 3)))
    }

    func testDayFilterClosesWindow() {
        let weekdaysOnly = settings(start: 0, end: 24 * 60 - 1, days: [2, 3, 4, 5, 6])
        XCTAssertFalse(DownloadManager.isWindowOpen(settings: weekdaysOnly, date: date(weekday: 1, hour: 12)))
        XCTAssertTrue(DownloadManager.isWindowOpen(settings: weekdaysOnly, date: date(weekday: 2, hour: 12)))
    }

    // MARK: Transfer statistics

    func testStatsRecordAccumulates() {
        var stats = TransferStats()
        stats.record(down: 1_000, up: 100)
        stats.record(down: 2_000, up: 0)
        XCTAssertEqual(stats.totalDownloadedBytes, 3_000)
        XCTAssertEqual(stats.totalUploadedBytes, 100)
        XCTAssertEqual(stats.today().down, 3_000)
    }

    func testStatsIgnoresNonPositiveDeltas() {
        var stats = TransferStats()
        stats.record(down: 0, up: 0)
        stats.record(down: -50, up: -1)
        XCTAssertEqual(stats.totalDownloadedBytes, 0)
        XCTAssertTrue(stats.perDay.isEmpty)
    }

    func testStatsLastDaysIncludesEmptyDays() {
        var stats = TransferStats()
        stats.record(down: 500, up: 0)
        let series = stats.lastDays(7)
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.last?.totals.down, 500)
        XCTAssertEqual(series.first?.totals.down, 0)
    }

    func testStatsRoundTripsThroughStore() throws {
        let store = try PersistenceStore()
        var stats = TransferStats()
        stats.record(down: 42, up: 7)
        stats.completedCount = 3
        try store.saveStats(stats)
        let loaded = try store.loadStats()
        XCTAssertEqual(loaded, stats)
    }

    // MARK: Backup pruning

    func testPruneBackupsKeepsNewest() throws {
        let dir = NSTemporaryDirectory() + "goel-prune-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for stamp in ["2026-01-01-000000", "2026-01-02-000000", "2026-01-03-000000",
                      "2026-01-04-000000", "2026-01-05-000000"] {
            FileManager.default.createFile(
                atPath: (dir as NSString).appendingPathComponent("backup-\(stamp).json"),
                contents: Data("[]".utf8))
        }
        // An unrelated file must never be touched.
        FileManager.default.createFile(
            atPath: (dir as NSString).appendingPathComponent("notes.txt"), contents: Data())

        DownloadManager.pruneBackups(in: dir, keep: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
        XCTAssertEqual(remaining, ["backup-2026-01-04-000000.json",
                                   "backup-2026-01-05-000000.json",
                                   "notes.txt"])
    }

    // MARK: RSS parsing

    func testParsesRSS2WithEnclosure() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>Ubuntu 26.04 ISO</title>
        <link>https://example.com/page</link>
        <guid>tag-1</guid>
        <enclosure url="https://example.com/ubuntu.iso" length="1" type="application/x-iso9660-image"/>
        </item>
        <item><title>No enclosure</title><link>https://example.com/direct.zip</link></item>
        </channel></rss>
        """
        let items = RSSFeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Ubuntu 26.04 ISO")
        XCTAssertEqual(items[0].enclosureURL, "https://example.com/ubuntu.iso")
        XCTAssertEqual(items[0].guid, "tag-1")
        XCTAssertEqual(items[1].link, "https://example.com/direct.zip")
        XCTAssertNil(items[1].enclosureURL)
    }

    func testParsesAtomLinks() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>Release v2</title><id>urn:x:1</id>
        <link href="https://example.com/v2.dmg"/></entry>
        </feed>
        """
        let items = RSSFeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].link, "https://example.com/v2.dmg")
        XCTAssertEqual(items[0].guid, "urn:x:1")
    }

    // MARK: Export envelope

    func testExportImportRoundTrip() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: try PersistenceStore())
        let source = DownloadSource.parse("https://example.com/file.bin")!
        _ = await manager.add(source: source)

        let data = try await manager.exportEnvelope()

        // Importing into a fresh manager recreates the task, paused-or-queued
        // state normalized, and adopts the settings.
        let fresh = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: try PersistenceStore())
        let added = try await fresh.importEnvelope(data)
        XCTAssertEqual(added, 1)
        let snapshot = await fresh.snapshot
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.source.dedupKey, source.dedupKey)

        // Importing the same envelope again adds nothing (dedup).
        let again = try await fresh.importEnvelope(data)
        XCTAssertEqual(again, 0)
    }

    func testImportSanitizesHostileNames() throws {
        let hostile = DownloadTask(
            source: DownloadSource.parse("https://example.com/a")!,
            name: "../../etc/passwd",
            saveDirectory: "relative/dir")
        let cleaned = PersistenceStore.sanitizedForImport(hostile)
        XCTAssertFalse(cleaned.name.contains("/"))
        XCTAssertTrue(cleaned.saveDirectory.hasPrefix("/"))
    }

    // MARK: Decode compatibility

    func testOldTaskBlobDecodesWithoutNewFields() throws {
        // A pre-batch task JSON: none of connections/seedCount/remoteInfo/
        // scanVerdict/speedLimitBytesPerSec/sequentialDownload exist.
        let task = DownloadTask(source: DownloadSource.parse("https://e.com/f.zip")!,
                                name: "f.zip", saveDirectory: "/tmp")
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(task)) as! [String: Any]
        for key in ["connections", "seedCount", "remoteInfo", "scanVerdict",
                    "speedLimitBytesPerSec", "sequentialDownload"] {
            json.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: stripped)
        XCTAssertEqual(decoded.name, "f.zip")
        XCTAssertNil(decoded.scanVerdict)
        XCTAssertNil(decoded.speedLimitBytesPerSec)
    }

    func testEmptySettingsBlobDecodesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.autoShutdownAction, "none")
        XCTAssertFalse(decoded.scheduleEnabled)
        XCTAssertEqual(decoded.backupKeepCount, 20)
        XCTAssertEqual(decoded.remotePort, 8899)
        XCTAssertTrue(decoded.rssFeeds.isEmpty)
    }

    // MARK: Review-fix regressions

    func testTorrentSuffixRespectsSchemeAllowlist() {
        // file:/data: .torrent locators must be rejected by the remote-input
        // parser; only http(s) .torrent URLs reach the torrent-file fetcher.
        // An ftp .torrent URL parses (FTP is a supported engine now) but must
        // route as a plain FTP file download, never into the fetcher.
        XCTAssertNil(DownloadSource.parse("file:///Users/x/evil.torrent"))
        if case .torrentFile = DownloadSource.parse("ftp://host/evil.torrent") {
            XCTFail("ftp .torrent URL must not route to the torrent-file fetcher")
        }
        XCTAssertEqual(DownloadSource.parse("ftp://host/evil.torrent")?.kind, .ftp)
        XCTAssertNotNil(DownloadSource.parse("https://example.com/ok.torrent"))
        XCTAssertNotNil(DownloadSource.parse("http://example.com/ok.torrent"))
    }

    func testImportedSettingsNeverAdoptDangerousFields() {
        var hostile = AppSettings()
        hostile.postDownloadScriptEnabled = true
        hostile.postDownloadScriptPath = "/usr/bin/curl"
        hostile.remoteAccessEnabled = true
        hostile.remoteAllowLAN = true
        hostile.remoteToken = "attacker"
        hostile.rssFeeds = [RSSFeed(url: "https://evil.example/feed")]
        hostile.btWatchFolderEnabled = true
        hostile.antivirusEnabled = true
        hostile.antivirusExecutablePath = "/tmp/evil"
        hostile.theme = "dark"   // benign field — must still be adopted

        let current = AppSettings()
        let safe = DownloadManager.sanitizedImportedSettings(hostile, current: current)
        XCTAssertFalse(safe.postDownloadScriptEnabled)
        XCTAssertEqual(safe.postDownloadScriptPath, "")
        XCTAssertFalse(safe.remoteAccessEnabled)
        XCTAssertFalse(safe.remoteAllowLAN)
        XCTAssertEqual(safe.remoteToken, "")
        XCTAssertTrue(safe.rssFeeds.isEmpty)
        XCTAssertFalse(safe.btWatchFolderEnabled)
        XCTAssertFalse(safe.antivirusEnabled)
        XCTAssertEqual(safe.antivirusExecutablePath, "")
        XCTAssertEqual(safe.theme, "dark")
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(RemoteControlServer.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(RemoteControlServer.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(RemoteControlServer.constantTimeEquals("abc", "abcd"))
        XCTAssertTrue(RemoteControlServer.constantTimeEquals("", ""))
    }

    func testStartPausedAddNeverSchedules() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: nil)
        let source = DownloadSource.parse("https://example.com/held.bin")!
        let task = await manager.add(source: source, startPaused: true)
        XCTAssertEqual(task.status, .paused)
        // Give any (wrongly) scheduled launch a chance to run, then re-check.
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await manager.task(task.id)
        XCTAssertEqual(after?.status, .paused)
    }

    // MARK: Version comparison (mirrors UpdateChecker.isNewer, kept in core-testable form)

    func testDottedVersionComparison() {
        XCTAssertTrue(isNewer("1.10", than: "1.9"))
        XCTAssertTrue(isNewer("2.0", than: "1.99.9"))
        XCTAssertFalse(isNewer("1.0", than: "1.0"))
        XCTAssertFalse(isNewer("1.0", than: "1.0.1"))
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
