import XCTest
import GoelCore
@testable import GoelApp

final class SpeedCapInputTests: XCTestCase {
    func testUnitsAndUnlimited() {
        XCTAssertEqual(SpeedCapInput.parse("5"), 5_000_000)
        XCTAssertEqual(SpeedCapInput.parse("500k"), 500_000)
        XCTAssertEqual(SpeedCapInput.parse("1.5 MB/s"), 1_500_000)
        XCTAssertEqual(SpeedCapInput.parse("2,5m"), 2_500_000)
        XCTAssertEqual(SpeedCapInput.parse("1g"), 1_000_000_000)
        XCTAssertEqual(SpeedCapInput.parse(""), 0)
        XCTAssertEqual(SpeedCapInput.parse("∞"), 0)
        XCTAssertNil(SpeedCapInput.parse("fast"))
        XCTAssertNil(SpeedCapInput.parse("-3"))
    }

    func testFormatRoundTrips() {
        XCTAssertEqual(SpeedCapInput.format(0), "")
        XCTAssertEqual(SpeedCapInput.format(5_000_000), "5")
        XCTAssertEqual(SpeedCapInput.parse(SpeedCapInput.format(750_000)), 750_000)
    }
}

final class ProfileScheduleSummaryTests: XCTestCase {
    func testRunsCollapseAdjacentHours() {
        var grid = Array(repeating: "", count: ProfileSchedule.slotCount)
        grid = ProfileSchedule.painting(grid, from: (1, 0), to: (1, 5), with: "Night")
        grid = ProfileSchedule.painting(grid, from: (1, 18), to: (1, 23), with: "Fast")
        XCTAssertEqual(ProfileScheduleSummary.runs(day: 1, grid: grid),
                       [.init(start: 0, end: 6, profile: "Night"), .init(start: 18, end: 24, profile: "Fast")])
        XCTAssertEqual(ProfileScheduleSummary.describe(day: 1, grid: grid), "00–06 Night, 18–24 Fast")
        XCTAssertTrue(ProfileScheduleSummary.runs(day: 0, grid: grid).isEmpty)
    }

    func testCellHitTestingClamps() {
        let size = CGSize(width: 240, height: 70)
        XCTAssertTrue(WeeklyProfileGrid.cell(at: CGPoint(x: 5, y: 5), size: size) == (0, 0))
        XCTAssertTrue(WeeklyProfileGrid.cell(at: CGPoint(x: 239, y: 69), size: size) == (6, 23))
        XCTAssertTrue(WeeklyProfileGrid.cell(at: CGPoint(x: -20, y: 500), size: size) == (6, 0))
    }
}

final class BrowserStatusTests: XCTestCase {
    func testBrowserNamedFromParentExecutable() {
        XCTAssertEqual(BrowserActivityLog.browserName(fromExecutablePath:
            "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/x"), "Brave")
        XCTAssertEqual(BrowserActivityLog.browserName(fromExecutablePath:
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), "Chrome")
        XCTAssertEqual(BrowserActivityLog.browserName(fromExecutablePath:
            "/Applications/Firefox.app/Contents/MacOS/firefox"), "Firefox")
        XCTAssertEqual(BrowserActivityLog.browserName(fromExecutablePath:
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"), "Edge")
    }

    func testActivityRecordsSeenAndCapture() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Date(timeIntervalSince1970: 1_000)
        BrowserActivityLog.record(.seen, browser: "Chrome", at: seen, to: url)
        XCTAssertEqual(BrowserActivityLog.read(from: url)["Chrome"]?.lastSeen, seen)
        XCTAssertNil(BrowserActivityLog.read(from: url)["Chrome"]?.lastCapture)
        let captured = Date(timeIntervalSince1970: 2_000)
        BrowserActivityLog.record(.capture, browser: "Chrome", at: captured, to: url)
        XCTAssertEqual(BrowserActivityLog.read(from: url)["Chrome"]?.lastCapture, captured)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testPrimaryFixOrder() {
        XCTAssertEqual(BrowserCard.primaryFix(for: BrowserStatus(name: "Chrome", helper: .missing)), .installHelper)
        XCTAssertEqual(BrowserCard.primaryFix(for: BrowserStatus(name: "Chrome", helper: .stale, lastSeen: Date())),
                       .installHelper)
        XCTAssertEqual(BrowserCard.primaryFix(for: BrowserStatus(name: "Chrome", helper: .installed)), .showExtension)
        XCTAssertEqual(BrowserCard.primaryFix(for: BrowserStatus(name: "Chrome", helper: .installed, lastSeen: Date())),
                       .none)
    }

    func testOnboardingChoices() {
        XCTAssertFalse(OnboardingBrowserChoice.safari.needsHelper)
        XCTAssertTrue(OnboardingBrowserChoice.brave.needsHelper)
        XCTAssertTrue(OnboardingBrowserChoice.firefox.loadHint.contains("about:debugging"))
    }
}

final class ToolbarSlotTests: XCTestCase {
    func testDefaultsMatchTheOriginalToolbar() {
        XCTAssertEqual(ToolbarSlot.decode(""), [.pauseResume, .search, .inspector])
        let raw = ToolbarSlot.toggling(.remove, in: "")
        XCTAssertTrue(ToolbarSlot.decode(raw).contains(.remove))
        XCTAssertEqual(ToolbarSlot.decode(ToolbarSlot.encode([])), [])
    }
}

final class Wave3MiscTextTests: XCTestCase {
    private func task(_ source: DownloadSource, status: DownloadStatus = .downloading) -> DownloadTask {
        DownloadTask(source: source, name: "a.zip", saveDirectory: "/tmp/x", totalBytes: 100, status: status)
    }

    func testRSSPlainTextStripsTags() {
        XCTAssertEqual(RSSText.plain("<p>Hi &amp; <b>bye</b></p><br/>x"), "Hi & bye\n\n\nx")
        XCTAssertEqual(RSSText.plain(nil), "")
    }

    func testExtraColumnText() {
        var http = task(.url(URL(string: "https://Files.Example.com/a.zip")!))
        http.tags = ["work", "iso"]
        XCTAssertEqual(ExtraColumnText.value(.host, task: http), "files.example.com")
        XCTAssertEqual(ExtraColumnText.value(.tags, task: http), "work, iso")
        XCTAssertEqual(ExtraColumnText.value(.protocol, task: http), "HTTP")
        XCTAssertEqual(ExtraColumnText.value(.ratio, task: http), "—")
        let magnet = task(.magnet("magnet:?xt=urn:btih:5C1A9D3E77AA0011223344556677889900AABBCC"))
        XCTAssertEqual(ExtraColumnText.value(.peers, task: magnet), "0/0")
        XCTAssertEqual(ExtraColumnText.value(.host, task: magnet), "—")
    }

    func testActiveDownloadLines() {
        var running = task(.url(URL(string: "https://e.test/a.zip")!))
        running.bytesDownloaded = 50
        let done = task(.url(URL(string: "https://e.test/b.zip")!), status: .completed)
        XCTAssertEqual(IntentSummaries.activeLines([running, done]), ["a.zip — 50%"])
    }

    func testTransferSummaryCounts() {
        var a = SFTPTransfer(connectionID: UUID(), name: "a", direction: .download, isDirectory: false,
                             localURL: nil, remotePath: "/a")
        a.state = .running
        var b = a
        b.state = .failed("boom")
        let summary = SFTPTransferSummary([a, b])
        XCTAssertEqual(summary.active, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.total, 2)
    }
}
