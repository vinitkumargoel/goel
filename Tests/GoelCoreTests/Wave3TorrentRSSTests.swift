import XCTest
@testable import GoelCore

final class TrackerListTests: XCTestCase {

    func testParseKeepsValidAnnounceURLsInOrderAndDedupes() {
        let text = """
        udp://tracker.opentrackr.org:1337/announce

        https://tracker.example.net/announce, http://t.example/announce
        UDP://TRACKER.OPENTRACKR.ORG:1337/announce
        not a url
        ftp://nope.example/announce
        magnet:?xt=urn:btih:abc
        """
        XCTAssertEqual(TrackerList.parse(text), [
            "udp://tracker.opentrackr.org:1337/announce",
            "https://tracker.example.net/announce",
            "http://t.example/announce",
        ])
    }

    func testValidationNeedsSchemeAndHost() {
        XCTAssertTrue(TrackerList.isValidAnnounceURL("wss://tracker.webtorrent.dev"))
        XCTAssertFalse(TrackerList.isValidAnnounceURL("udp://"))
        XCTAssertFalse(TrackerList.isValidAnnounceURL("tracker.example.com:80"))
        XCTAssertFalse(TrackerList.isValidAnnounceURL(""))
    }

    func testMergingAppendsOnlyNewURLs() {
        XCTAssertEqual(TrackerList.merging(["udp://a/x", "udp://b/x"], ["UDP://A/x", "udp://c/x"]),
                       ["udp://a/x", "udp://b/x", "udp://c/x"])
    }

    func testRefreshIsDailyAndSurvivesClockSkew() {
        let now = Date()
        XCTAssertTrue(TrackerList.needsRefresh(lastUpdated: nil, now: now))
        XCTAssertFalse(TrackerList.needsRefresh(lastUpdated: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(TrackerList.needsRefresh(lastUpdated: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(TrackerList.needsRefresh(lastUpdated: now.addingTimeInterval(3600), now: now),
                      "a timestamp in the future (clock moved back) must not freeze the list")
    }
}

final class ProfileScheduleTests: XCTestCase {

    // 2026-07-05 is a Sunday.
    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 5 + (weekday - 1); c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func decide(_ settings: AppSettings, at now: Date,
                        memory: AutomationCore.Memory = .init()) -> AutomationCore.Decision {
        AutomationCore.decide(.init(now: now, calendar: .current, settings: settings, tasks: [],
                                    networkExpensive: false, networkConstrained: false,
                                    feeds: [], memory: memory))
    }

    func testSlotIsDayTimes24PlusHourFromSunday() {
        XCTAssertEqual(ProfileSchedule.slot(for: date(weekday: 1, hour: 0)), 0)
        XCTAssertEqual(ProfileSchedule.slot(for: date(weekday: 2, hour: 9, minute: 30)), 33)
        XCTAssertEqual(ProfileSchedule.slot(for: date(weekday: 7, hour: 23)), 167)
    }

    func testPaintingFillsTheDragRectangleInEitherDirection() {
        let grid = ProfileSchedule.painting([], from: (day: 2, hour: 10), to: (day: 1, hour: 9), with: "Low")
        XCTAssertEqual(grid.count, ProfileSchedule.slotCount)
        XCTAssertEqual(grid.filter { $0 == "Low" }.count, 4)
        XCTAssertEqual(grid[1 * 24 + 9], "Low")
        XCTAssertEqual(grid[2 * 24 + 10], "Low")
        XCTAssertEqual(ProfileSchedule.painting(grid, from: (1, 9), to: (1, 9), with: "")[1 * 24 + 9], "")
    }

    func testPrunedDropsDeletedProfiles() {
        let grid = ProfileSchedule.painting([], from: (0, 0), to: (0, 1), with: "Gone")
        XCTAssertTrue(ProfileSchedule.pruned(grid, keeping: ["Low"]).allSatisfy(\.isEmpty))
    }

    func testEnteringAPaintedHourActivatesItsProfileOnce() {
        var settings = AppSettings(selectedProfileName: "High")
        settings.profileScheduleEnabled = true
        settings.profileSchedule = ProfileSchedule.painting([], from: (1, 9), to: (1, 17), with: "Low")
        let first = decide(settings, at: date(weekday: 2, hour: 9))
        XCTAssertEqual(first.actions, [.activateProfile("Low")])

        // A manual switch back to High within the same hour is not overridden.
        let again = decide(settings, at: date(weekday: 2, hour: 9, minute: 40), memory: first.memory)
        XCTAssertTrue(again.actions.isEmpty)
    }

    func testUnpaintedHoursAndDisabledGridDoNothing() {
        var settings = AppSettings(selectedProfileName: "High")
        settings.profileSchedule = ProfileSchedule.painting([], from: (1, 9), to: (1, 9), with: "Low")
        XCTAssertTrue(decide(settings, at: date(weekday: 2, hour: 9)).actions.isEmpty, "grid off")
        settings.profileScheduleEnabled = true
        XCTAssertTrue(decide(settings, at: date(weekday: 2, hour: 11)).actions.isEmpty, "blank hour")
    }

    func testUnknownProfileIsIgnored() {
        var settings = AppSettings(selectedProfileName: "High")
        settings.profileScheduleEnabled = true
        settings.profileSchedule = ProfileSchedule.painting([], from: (1, 9), to: (1, 9), with: "Nope")
        XCTAssertTrue(decide(settings, at: date(weekday: 2, hour: 9)).actions.isEmpty)
    }

    func testSettingsRoundTripAndLegacyDecode() throws {
        var s = AppSettings()
        s.profileScheduleEnabled = true
        s.profileSchedule = ProfileSchedule.normalized(["Low"])
        s.extraTrackersEnabled = true
        s.extraTrackersURL = "https://example.test/list.txt"
        s.extraTrackers = ["udp://a.example:1/announce"]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.profileSchedule.count, 168)
        XCTAssertEqual(back.extraTrackers, s.extraTrackers)
        XCTAssertTrue(back.extraTrackersEnabled)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.profileScheduleEnabled)
        XCTAssertTrue(legacy.extraTrackers.isEmpty)
    }
}

final class RSSRuleMatcherTests: XCTestCase {

    private func feed(_ include: String = "", exclude: String = "", episodes: String = "") -> RSSFeed {
        RSSFeed(url: "https://example.test/rss", titlePattern: include,
                mustNotContain: exclude, episodeFilter: episodes)
    }

    func testMustContainAcceptsAlternatives() {
        let f = feed("1080p|2160p")
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Show S01E01 2160p WEB", feed: f))
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show S01E01 720p", feed: f))
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Anything", feed: feed()))
    }

    func testMustNotContainRejects() {
        let f = feed("Show", exclude: "CAM | hdts")
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show 2026 HDTS", feed: f))
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Show 2026 WEB", feed: f))
    }

    func testEpisodeFilterRangesAndOpenEnds() {
        let f = feed(episodes: "1x2;8-10;20-")
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Show.S01E02.1080p", feed: f))
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Show 1x09", feed: f))
        XCTAssertTrue(RSSRuleMatcher.matches(title: "Show s1e25", feed: f))
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show.S01E05", feed: f))
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show.S02E02", feed: f))
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show special", feed: f), "no episode number")
    }

    func testMalformedEpisodeFilterMatchesNothing() {
        XCTAssertNil(RSSRuleMatcher.EpisodeFilter("banana"))
        XCTAssertFalse(RSSRuleMatcher.matches(title: "Show S01E01", feed: feed(episodes: "banana")))
    }

    func testLegacyFeedDecodesWithEmptyNewFields() throws {
        let json = #"{"id":"6D2A4E0B-3F1C-4B4E-9E8C-1D2C3B4A5F60","url":"https://x.test/rss","titlePattern":"a","enabled":true,"startPaused":false}"#
        let f = try JSONDecoder().decode(RSSFeed.self, from: Data(json.utf8))
        XCTAssertEqual(f.titlePattern, "a")
        XCTAssertEqual(f.mustNotContain, "")
        XCTAssertEqual(f.episodeFilter, "")
        XCTAssertEqual(f.displayName, "x.test")
    }

    func testParserReadsSummaryAndDate() {
        let xml = """
        <rss><channel><item><title>A</title><link>https://x.test/a.torrent</link>
        <guid>g1</guid><description>Hello</description><pubDate>Tue, 01 Sep 2026 10:00:00 GMT</pubDate>
        </item></channel></rss>
        """
        let items = RSSFeedReader.parse(Data(xml.utf8))
        XCTAssertEqual(items.first?.summary, "Hello")
        XCTAssertEqual(items.first?.published, "Tue, 01 Sep 2026 10:00:00 GMT")
        XCTAssertEqual(items.first?.key, "g1")
        XCTAssertEqual(items.first?.locator, "https://x.test/a.torrent")
    }
}

final class TorrentCreatorTests: XCTestCase {

    func testCreatesATorrentFromAFolderAndReportsProgress() async throws {
        let root = NSTemporaryDirectory() + "goel-create-\(UUID().uuidString)"
        let folder = root + "/Share"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: folder + "/a.bin"))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: folder + "/b.txt"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/.DS_Store"))

        let out = TorrentCreator.defaultOutputPath(for: folder)
        let seen = CreateProgressCounter()
        let url = try await TorrentCreator.create(
            .init(sourcePath: folder, outputPath: out, trackers: ["udp://tracker.example:1337/announce"],
                  pieceSize: 1 << 16, isPrivate: true, comment: "test")) { _ in
            seen.increment(); return true
        }
        XCTAssertEqual(url.path, root + "/Share.torrent")
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("d"), "bencoded dictionary")
        XCTAssertTrue(text.contains("udp://tracker.example:1337/announce"))
        XCTAssertTrue(text.contains("7:privatei1e"))
        XCTAssertFalse(text.contains(".DS_Store"), "hidden files are left out")
        XCTAssertGreaterThan(seen.value, 0)
    }

    func testCancellingStopsAndWritesNothing() async throws {
        let root = NSTemporaryDirectory() + "goel-cancel-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/big.bin"
        try Data(repeating: 1, count: 1 << 20).write(to: URL(fileURLWithPath: file))
        let out = root + "/big.torrent"
        do {
            _ = try await TorrentCreator.create(.init(sourcePath: file, outputPath: out, pieceSize: 1 << 16)) { _ in false }
            XCTFail("expected cancellation")
        } catch let error as TorrentCreator.Failure {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testEmptyFolderFails() async throws {
        let root = NSTemporaryDirectory() + "goel-empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        do {
            _ = try await TorrentCreator.create(.init(sourcePath: root, outputPath: root + ".torrent")) { _ in true }
            XCTFail("expected failure")
        } catch let error as TorrentCreator.Failure {
            if case .failed = error {} else { XCTFail("got \(error)") }
        }
    }
}

final class TrackerEditingTests: XCTestCase {

    private func manager(with task: DownloadTask) async throws -> DownloadManager {
        let store = try PersistenceStore()
        try store.upsert(task)
        let m = DownloadManager(httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
                                settings: AppSettings(), store: store)
        await m.restore()
        return m
    }

    private func torrent() -> DownloadTask {
        var t = DownloadTask(source: .magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"),
                             name: "t", saveDirectory: "/tmp")
        t.status = .paused
        t.trackers = [TorrentTracker(url: "udp://a.example:1/announce")]
        return t
    }

    func testAddSkipsDuplicatesAndInvalidAndBumpsTier() async throws {
        let t = torrent()
        let m = try await manager(with: t)
        let added = await m.addTrackers(["udp://A.example:1/announce", "junk", "https://b.example/announce"], task: t.id)
        XCTAssertEqual(added, 1)
        let trackers = await m.task(t.id)?.trackers ?? []
        XCTAssertEqual(trackers.map(\.url), ["udp://a.example:1/announce", "https://b.example/announce"])
        XCTAssertEqual(trackers.last?.tier, 1)
    }

    func testEditAndRemove() async throws {
        let t = torrent()
        let m = try await manager(with: t)
        let ok = await m.editTracker("udp://a.example:1/announce", to: "udp://c.example:2/announce", task: t.id)
        XCTAssertTrue(ok)
        let bad = await m.editTracker("udp://c.example:2/announce", to: "nope", task: t.id)
        XCTAssertFalse(bad)
        await m.removeTrackers(["udp://c.example:2/announce"], task: t.id)
        let remaining = await m.task(t.id)?.trackers ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNonTorrentIsANoOp() async throws {
        var t = DownloadTask(source: .url(URL(string: "https://example.test/x.bin")!), name: "x", saveDirectory: "/tmp")
        t.status = .paused
        let m = try await manager(with: t)
        let added = await m.addTrackers(["udp://a.example:1/announce"], task: t.id)
        XCTAssertEqual(added, 0)
    }
}

private final class CreateProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
