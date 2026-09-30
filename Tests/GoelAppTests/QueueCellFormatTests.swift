import XCTest
import GoelCore
@testable import GoelApp

/// The list's merged Speed cell, the compact Added column and the menu bar's failure section.
final class QueueCellFormatTests: XCTestCase {

    private let english = Locale(identifier: "en_US")
    private let british = Locale(identifier: "en_GB")

    private func at(_ day: Int, _ hour: Int, _ minute: Int, from base: Date = Date()) -> Date {
        let calendar = Calendar.current
        let shifted = calendar.date(byAdding: .day, value: day, to: base)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted)!
    }

    // MARK: Speed cell

    func testAnIdleRowShowsNothingRatherThanDashes() {
        let cell = SpeedCellText(speed: .zero, isTorrent: false)
        XCTAssertNil(cell.down)
        XCTAssertNil(cell.up)
        XCTAssertTrue(cell.isEmpty)
        XCTAssertTrue(SpeedCellText(speed: .zero, isTorrent: true).isEmpty,
                      "a torrent at rest is idle too")
    }

    func testAPlainDownloadHasNoUploadLine() {
        let cell = SpeedCellText(speed: SpeedSample(down: 2_000_000, up: 0), isTorrent: false)
        XCTAssertEqual(cell.down, "↓ " + 2_000_000.0.speedString)
        XCTAssertNil(cell.up)
    }

    func testTheUploadLineAppearsWhenUploading() {
        let cell = SpeedCellText(speed: SpeedSample(down: 0, up: 1_800_000), isTorrent: true)
        XCTAssertNil(cell.down)
        XCTAssertEqual(cell.up, "↑ " + 1_800_000.0.speedString)
    }

    func testADownloadingTorrentAlwaysShowsItsUploadLine() {
        let cell = SpeedCellText(speed: SpeedSample(down: 5_000_000, up: 0), isTorrent: true)
        XCTAssertNotNil(cell.down)
        XCTAssertNotNil(cell.up)
        XCTAssertFalse(cell.up!.contains("—"), cell.up!)
    }

    func testSubByteNoiseCountsAsIdle() {
        XCTAssertTrue(SpeedCellText(speed: SpeedSample(down: 0.4, up: 0.2), isTorrent: false).isEmpty)
    }

    // MARK: Added column

    func testTodayIsJustTheTime() {
        let now = at(0, 15, 0)
        XCTAssertEqual(DisplayFormat.compactDateTime(at(0, 14, 3, from: now), locale: british, now: now), "14:03")
    }

    func testYesterdayIsAbbreviatedWithTheTime() {
        let now = at(0, 15, 0)
        let text = DisplayFormat.compactDateTime(at(-1, 14, 2, from: now), locale: british, now: now)
        XCTAssertEqual(text, "Yest 14:02")
    }

    func testOlderDatesAreAbbreviatedMonthAndDay() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let march = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9))!
        XCTAssertEqual(DisplayFormat.compactDateTime(march, locale: british, now: now), "12 Mar")
        XCTAssertEqual(DisplayFormat.compactDateTime(march, locale: english, now: now), "Mar 12")
    }

    func testAnotherYearKeepsTheYear() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
        let old = calendar.date(from: DateComponents(year: 2025, month: 3, day: 12, hour: 9))!
        let text = DisplayFormat.compactDateTime(old, locale: english, now: now)
        XCTAssertTrue(text.contains("25"), text)
        XCTAssertLessThanOrEqual(text.count, 12, text)
    }

    // MARK: Menu bar "Needs attention"

    private func task(_ name: String, status: DownloadStatus, added: TimeInterval) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                     name: name, saveDirectory: "/tmp", totalBytes: 100, status: status,
                     addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + added))
    }

    private let oops = DownloadError.diskFull(needed: 100, available: 10)

    func testNeedsAttentionListsOnlyFailuresNewestFirstUpToThree() {
        let tasks = [
            task("a", status: .failed(oops), added: 1),
            task("b", status: .downloading, added: 2),
            task("c", status: .failed(oops), added: 3),
            task("d", status: .failed(oops), added: 4),
            task("e", status: .completed, added: 5),
            task("f", status: .failed(oops), added: 6),
        ]
        let attention = MenuBarAttention(tasks: tasks)
        XCTAssertEqual(attention.shown.map(\.name), ["f", "d", "c"])
        XCTAssertEqual(attention.total, 4)
    }

    func testNeedsAttentionTopNMatchesAFullSort() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<40 {
            let count = Int.random(in: 0...30, using: &generator)
            let tasks = (0..<count).map { n in
                task("t\(n)",
                     status: Bool.random(using: &generator) ? .failed(oops) : .downloading,
                     // A narrow range forces ties, which must keep list order like a stable sort.
                     added: TimeInterval(Int.random(in: 0...8, using: &generator)))
            }
            for limit in [0, 1, 3, 5] {
                let failed = tasks.filter { $0.status.isFailed }
                let expected = failed.enumerated()
                    .sorted { $0.element.addedAt != $1.element.addedAt
                        ? $0.element.addedAt > $1.element.addedAt : $0.offset < $1.offset }
                    .prefix(limit).map(\.element.name)
                let attention = MenuBarAttention(tasks: tasks, limit: limit)
                XCTAssertEqual(attention.shown.map(\.name), Array(expected), "round \(round), limit \(limit)")
                XCTAssertEqual(attention.total, failed.count)
            }
        }
    }

    func testNoFailuresMeansNoSection() {
        let attention = MenuBarAttention(tasks: [task("a", status: .queued, added: 1)])
        XCTAssertTrue(attention.shown.isEmpty)
        XCTAssertEqual(attention.total, 0)
    }

    // MARK: Link grabber prefill

    func testLinkGrabberPrefillsTheFirstWebLink() {
        XCTAssertEqual(LinkGrabberPrefill.pageURL(fromClipboard: "see https://example.org/files/ and more"),
                       "https://example.org/files/")
        XCTAssertEqual(LinkGrabberPrefill.pageURL(fromClipboard: "magnet:?xt=urn:btih:abc\nhttp://a.test/x"),
                       "http://a.test/x")
    }

    func testLinkGrabberIgnoresClipboardsWithoutAWebLink() {
        XCTAssertNil(LinkGrabberPrefill.pageURL(fromClipboard: "just some words"))
        XCTAssertNil(LinkGrabberPrefill.pageURL(fromClipboard: "ftp://host/file.iso"))
        XCTAssertNil(LinkGrabberPrefill.pageURL(fromClipboard: ""))
    }

    // MARK: Layout values

    func testTheBottomPanelHeightIsClamped() {
        XCTAssertEqual(DetailPanelHeight.clamped(100), 220)
        XCTAssertEqual(DetailPanelHeight.clamped(900), 480)
        XCTAssertEqual(DetailPanelHeight.clamped(333), 333)
        XCTAssertEqual(DetailPanelHeight.clamped(.nan), DetailPanelHeight.standard)
    }

    func testTheBottomPanelYieldsToTheListInAShortWindow() {
        // A tall column leaves the preference alone.
        XCTAssertEqual(DetailPanelHeight.fitted(480, available: 900), 480)
        // A 620 pt window leaves about 540 pt for the column: the list keeps its 220.
        XCTAssertEqual(DetailPanelHeight.fitted(480, available: 540), 320)
        XCTAssertEqual(DetailPanelHeight.fitted(300, available: 540), 300)
        // Out-of-range preferences are clamped first.
        XCTAssertEqual(DetailPanelHeight.fitted(9000, available: 2000), 480)
        // Never below the floor, even with almost no room.
        XCTAssertEqual(DetailPanelHeight.fitted(480, available: 250), DetailPanelHeight.floor)
        // Before the column is measured, the preference stands.
        XCTAssertEqual(DetailPanelHeight.fitted(400, available: 0), 400)
        XCTAssertEqual(DetailPanelHeight.fitted(400, available: .infinity), 400)
    }

    func testColumnsScaleWithTextSizeAndStatusGetsTheRoom() {
        let base = DownloadColumns()
        let large = DownloadColumns(scale: 1.5)
        XCTAssertEqual(large.status, (base.status * 1.5).rounded())
        XCTAssertGreaterThanOrEqual(base.status, 150)
        XCTAssertEqual(DownloadColumns(scale: 0), base, "a bad factor falls back to 1")
    }
}
