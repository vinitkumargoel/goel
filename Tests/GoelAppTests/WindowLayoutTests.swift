import XCTest
import GoelCore
@testable import GoelApp

private func task(_ name: String = "file.zip",
                  source: DownloadSource? = nil,
                  total: Int64? = 1_000,
                  done: Int64 = 0,
                  status: DownloadStatus = .queued,
                  files: [TransferFile] = [],
                  label: String? = nil,
                  tags: [String]? = nil) -> DownloadTask {
    DownloadTask(source: source ?? .url(URL(string: "https://example.test/\(name)")!),
                 name: name, saveDirectory: "/tmp", totalBytes: total, bytesDownloaded: done,
                 status: status, files: files, label: label, tags: tags)
}

final class DownloadColumnsLayoutTests: XCTestCase {

    private let base = DownloadColumns()

    func testUnmeasuredWidthKeepsTheFullSet() {
        XCTAssertEqual(DownloadColumns.layout(for: 0, columns: base), .full)
        XCTAssertEqual(DownloadColumns.layout(for: .infinity, columns: base), .full)
        XCTAssertEqual(DownloadColumns(scale: 1, listWidth: 0).layout, .full)
    }

    func testColumnsDropInOrderAsTheListNarrows() {
        XCTAssertEqual(DownloadColumns.layout(for: 1200, columns: base), .full)
        XCTAssertEqual(DownloadColumns.layout(for: 700, columns: base), .noAdded)
        XCTAssertEqual(DownloadColumns.layout(for: 500, columns: base), .compact)
    }

    /// At every threshold the name keeps at least its minimum width.
    func testTheNameNeverDropsBelowItsMinimum() {
        let fixed: (DownloadColumns.Layout) -> CGFloat = { layout in
            var width = self.base.index + self.base.status + 2 * DownloadColumns.cellPadding
                + DownloadColumns.rowPadding + DownloadColumns.cellPadding
            if layout != .compact {
                width += self.base.size + self.base.speed + 2 * DownloadColumns.cellPadding
            }
            if layout == .full { width += self.base.added + DownloadColumns.cellPadding }
            return width
        }
        for width in stride(from: CGFloat(560), through: 1400, by: 10) {
            let layout = DownloadColumns.layout(for: width, columns: base)
            guard layout != .compact else { continue }
            XCTAssertGreaterThanOrEqual(width - fixed(layout), DownloadColumns.minimumNameWidth, "at \(width)")
        }
    }

    func testVisibilityFlagsFollowTheLayout() {
        var columns = base
        columns.layout = .noAdded
        XCTAssertTrue(columns.showsSize)
        XCTAssertFalse(columns.showsAdded)
        XCTAssertTrue(columns.showsSpeed)
        columns.layout = .compact
        XCTAssertFalse(columns.showsSize)
        XCTAssertFalse(columns.showsSpeed)
    }

    func testLargerTextNeedsAWiderListForTheSameSet() {
        let scaled = DownloadColumns(scale: 1.3)
        let width: CGFloat = 740
        XCTAssertEqual(DownloadColumns.layout(for: width, columns: base), .full)
        XCTAssertNotEqual(DownloadColumns.layout(for: width, columns: scaled), .full)
    }
}

final class WindowLayoutTests: XCTestCase {

    func testAWideWindowKeepsTheRightDock() {
        XCTAssertEqual(WindowLayout.detailPosition(preferred: .right, windowWidth: 1440, sidebarVisible: true), .right)
    }

    func testANarrowWindowDocksTheDetailPanelAtTheBottom() {
        XCTAssertEqual(WindowLayout.detailPosition(preferred: .right, windowWidth: 900, sidebarVisible: true), .bottom)
        // Hiding the sidebar frees enough room for the right dock again.
        XCTAssertEqual(WindowLayout.detailPosition(preferred: .right, windowWidth: 900, sidebarVisible: false), .right)
    }

    func testABottomPreferenceIsNeverOverridden() {
        XCTAssertEqual(WindowLayout.detailPosition(preferred: .bottom, windowWidth: 2000, sidebarVisible: true), .bottom)
    }

    func testAnUnmeasuredWindowKeepsThePreference() {
        XCTAssertEqual(WindowLayout.detailPosition(preferred: .right, windowWidth: 0, sidebarVisible: true), .right)
    }

    func testTheMinimumWindowFitsSidebarAndList() {
        XCTAssertGreaterThanOrEqual(WindowLayout.minimumWindowWidth,
                                    WindowLayout.sidebarWidth + 1 + WindowLayout.minimumListWidth)
    }
}

final class QueueOverviewTests: XCTestCase {

    private func overview(_ tasks: [DownloadTask], down: Double = 0) -> QueueOverview {
        QueueOverview(tasks: tasks) { $0.status == .downloading ? SpeedSample(down: down, up: 0) : .zero }
    }

    func testCountsEachStatusOnce() {
        let o = overview([task(status: .downloading), task(status: .queued), task(status: .queued),
                          task(status: .completed), task(status: .seeding), task(status: .failed(.httpStatus(404))),
                          task(status: .paused)])
        XCTAssertEqual(o.active, 1, "seeding is done, not active")
        XCTAssertEqual(o.queued, 2)
        XCTAssertEqual(o.done, 2)
        XCTAssertEqual(o.failed, 1)
    }

    func testRemainingSkipsPausedAndFinishedRows() {
        let o = overview([task(total: 1_000, done: 400, status: .downloading),
                          task(total: 500, status: .queued),
                          task(total: 9_000, done: 1, status: .paused),
                          task(total: 7_000, done: 7_000, status: .completed)])
        XCTAssertEqual(o.remainingBytes, 1_100)
        XCTAssertFalse(o.hasUnknownSize)
    }

    func testEtaIsRemainingOverCombinedSpeed() {
        let o = overview([task(total: 1_000, done: 0, status: .downloading)], down: 100)
        XCTAssertEqual(o.eta ?? 0, 10, accuracy: 0.001)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(o.doneAt(now: now), now.addingTimeInterval(10))
    }

    func testNoEtaWhenIdleOrNothingLeft() {
        XCTAssertNil(overview([task(status: .queued)]).eta, "no speed")
        XCTAssertNil(overview([task(total: 10, done: 10, status: .completed)], down: 100).eta)
        XCTAssertNil(overview([]).doneText())
    }

    func testAnUnknownSizeMakesTheEstimateALowerBound() {
        let o = overview([task(total: nil, status: .downloading), task(total: 1_000, status: .queued)], down: 100)
        XCTAssertTrue(o.hasUnknownSize)
        XCTAssertTrue(o.doneText()?.hasPrefix("done ≥") ?? false)
        let known = overview([task(total: 1_000, status: .downloading)], down: 100)
        XCTAssertTrue(known.doneText()?.hasPrefix("done ≈") ?? false)
    }

    func testClockTextAddsTheDayOnlyWhenItIsNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_700_000_000)          // Tue 14 Nov 2023, 22:13 UTC
        let later = now.addingTimeInterval(600)
        XCTAssertEqual(QueueOverview.clockText(later, now: now, locale: locale, calendar: calendar), "22:23")
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertTrue(QueueOverview.clockText(tomorrow, now: now, locale: locale, calendar: calendar).hasPrefix("Wed"))
    }
}

final class CompactListTextTests: XCTestCase {

    func testSpeedFoldsIntoStatusWhileDownloading() {
        let t = task(status: .downloading)
        let text = t.statusFoldedText(speed: SpeedSample(down: 2_000_000, up: 0))
        XCTAssertTrue(text.hasPrefix("↓ "), text)
        XCTAssertTrue(text.contains(" · "), text)
        XCTAssertEqual(t.statusFoldedText(speed: .zero), t.statusCompactText())
    }

    func testSeedingLeadsWithUpload() {
        let t = task(status: .seeding)
        XCTAssertTrue(t.statusFoldedText(speed: SpeedSample(down: 0, up: 5_000)).hasPrefix("↑ "))
    }

    func testOtherStatesAreUnchanged() {
        let t = task(status: .paused)
        XCTAssertEqual(t.statusFoldedText(speed: SpeedSample(down: 9_999, up: 0)), t.statusCompactText())
    }

    func testSizeLine() {
        let running = task(total: 2_000_000_000, done: 1_000_000_000, status: .downloading)
        XCTAssertTrue(running.compactSizeLine.hasSuffix("50%"), running.compactSizeLine)
        XCTAssertTrue(running.compactSizeLine.contains(" · "))
        let finished = task(total: 2_000_000_000, done: 2_000_000_000, status: .completed)
        XCTAssertFalse(finished.compactSizeLine.contains("%"))
        XCTAssertEqual(task(total: nil, status: .completed).compactSizeLine, "")
        XCTAssertTrue(task(total: nil, status: .downloading).compactSizeLine.hasSuffix("%"))
    }
}

final class DetailTabTests: XCTestCase {

    func testASingleFileHasNoFilesTab() {
        XCTAssertEqual(DetailTab.available(for: task()), [.overview, .network])
        XCTAssertEqual(DetailTab.files.resolved(for: task()), .overview)
        XCTAssertEqual(DetailTab.network.resolved(for: task()), .network)
    }

    func testTorrentsAndMultiFileDownloadsShowFiles() {
        let torrent = task(source: .magnet("magnet:?xt=urn:btih:abc"))
        XCTAssertEqual(DetailTab.available(for: torrent), DetailTab.allCases)
        let multi = task(files: [TransferFile(id: 0, path: "a", length: 1),
                                 TransferFile(id: 1, path: "b", length: 1)])
        XCTAssertEqual(DetailTab.files.resolved(for: multi), .files)
    }
}

@MainActor
final class TagOperationTests: XCTestCase {

    func testRenameRewritesTagsAndLabelCaseInsensitively() {
        let a = task(tags: ["Work", "urgent"])
        let b = task(label: "work")
        let c = task(tags: ["home"])
        let changes = AppViewModel.retagged([a, b, c], tag: "WORK", replacement: "Job")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first { $0.id == a.id }?.tags, ["Job", "urgent"])
        let labelChange = changes.first { $0.id == b.id }?.label
        XCTAssertEqual(labelChange, .some(.some("Job")))
    }

    func testRemoveDropsTheTagAndClearsAMatchingLabel() {
        let a = task(tags: ["work", "urgent"])
        let b = task(label: "Work")
        let changes = AppViewModel.retagged([a, b], tag: "work", replacement: nil)
        XCTAssertEqual(changes.first { $0.id == a.id }?.tags, ["urgent"])
        let cleared = changes.first { $0.id == b.id }?.label
        XCTAssertEqual(cleared, .some(.none))
    }

    func testRenamingOntoAnExistingTagDoesNotDuplicateIt() {
        let a = task(tags: ["work", "Job"])
        let changes = AppViewModel.retagged([a], tag: "work", replacement: "job")
        XCTAssertEqual(changes.first?.tags, ["job"])
    }

    func testTagColourOverridesWinAndRoundTrip() {
        let map = ["work": 3]
        XCTAssertEqual(TagColors.decode(TagColors.encode(map)), map)
        XCTAssertEqual(TagColors.decode("not json"), [:])
        XCTAssertEqual(TagColors.slot(for: "Work", overrides: map, slots: 8), 3)
        XCTAssertEqual(TagColors.slot(for: "home", overrides: map, slots: 8),
                       ListPresentation.tagColorSlot("home", slots: 8))
        XCTAssertEqual(TagColors.slot(for: "work", overrides: ["work": 99], slots: 8),
                       ListPresentation.tagColorSlot("work", slots: 8), "an out-of-range pick falls back")
    }
}

final class HistoryPresentationTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue 14 Nov 2023, 22:13 UTC

    private func entry(_ name: String, daysAgo: Double, bytes: Int64? = 100) -> HistoryEntry {
        HistoryEntry(id: UUID(), name: name, locator: "https://example.test/\(name)", kind: .http,
                     totalBytes: bytes, savePath: "/tmp/\(name)",
                     completedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testSectionsByAge() {
        typealias S = HistoryPresentation.Section
        XCTAssertEqual(S.of(now.addingTimeInterval(-3600), now: now, calendar: calendar), .today)
        XCTAssertEqual(S.of(now.addingTimeInterval(-86_400), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(S.of(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(S.of(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar), .older)
        XCTAssertEqual(S.of(now.addingTimeInterval(3600), now: now, calendar: calendar), .today, "clock skew")
    }

    func testFileExistenceIsCheckedOncePerEntry() {
        var checks = 0
        let items = HistoryPresentation.items([entry("a.mp4", daysAgo: 0), entry("b.zip", daysAgo: 1)]) { path in
            checks += 1
            return path.hasSuffix("a.mp4")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(items.map(\.exists), [true, false])
        XCTAssertEqual(items.map(\.type), [.video, .archive])
        XCTAssertEqual(HistoryPresentation.types(in: items), [.video, .archive])
    }

    func testFilterBySearchAndType() {
        let items = HistoryPresentation.items([entry("movie.mp4", daysAgo: 0), entry("backup.zip", daysAgo: 0)]) { _ in true }
        XCTAssertEqual(HistoryPresentation.filtered(items, query: "MOVIE", type: nil).map(\.entry.name), ["movie.mp4"])
        XCTAssertEqual(HistoryPresentation.filtered(items, query: "", type: .archive).map(\.entry.name), ["backup.zip"])
        XCTAssertEqual(HistoryPresentation.filtered(items, query: "movie", type: .archive), [])
    }

    func testSectionsSortInsideEachGroup() {
        let items = HistoryPresentation.items([
            entry("small-new", daysAgo: 0.01, bytes: 10),
            entry("big-old", daysAgo: 0.02, bytes: 900),
            entry("last-month", daysAgo: 40, bytes: 5),
        ]) { _ in true }
        let byDate = HistoryPresentation.sections(items, sort: .date, now: now, calendar: calendar)
        XCTAssertEqual(byDate.map(\.section), [.today, .older])
        XCTAssertEqual(byDate[0].items.map(\.entry.name), ["small-new", "big-old"])
        let bySize = HistoryPresentation.sections(items, sort: .size, now: now, calendar: calendar)
        XCTAssertEqual(bySize[0].items.map(\.entry.name), ["big-old", "small-new"])
    }

    func testFooterCountsItemsAndBytes() {
        let items = HistoryPresentation.items([entry("a", daysAgo: 0, bytes: 1_000_000),
                                               entry("b", daysAgo: 0, bytes: nil)]) { _ in true }
        let text = HistoryPresentation.footer(items)
        XCTAssertTrue(text.hasPrefix("2 items · "), text)
        XCTAssertEqual(HistoryPresentation.footer(Array(items.suffix(1))), "1 item")
    }
}

final class Wave2ReviewFixTests: XCTestCase {

    func testTagColourFollowsARename() {
        let map = ["work": 3, "home": 1]
        XCTAssertEqual(TagColors.renamed(map, from: "Work", to: "Job"), ["job": 3, "home": 1])
        XCTAssertEqual(TagColors.renamed(map, from: "unknown", to: "x"), map, "no pick, nothing to move")
        XCTAssertEqual(TagColors.renamed(["work": 3, "job": 5], from: "work", to: "Job"), ["job": 3],
                       "the renamed tag's colour wins")
    }

    func testRemovingATagForgetsItsColour() {
        XCTAssertEqual(TagColors.removed(["work": 3, "home": 1], tag: "WORK"), ["home": 1])
        XCTAssertEqual(TagColors.setting([:], tag: "Work", slot: 2), ["work": 2])
    }

    func testUpdateWritesThroughToDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "wave2.tagcolors.\(UUID().uuidString)"))
        defaults.set(TagColors.encode(["work": 4]), forKey: TagColors.storageKey)
        TagColors.update({ TagColors.renamed($0, from: "work", to: "job") }, defaults: defaults)
        XCTAssertEqual(TagColors.decode(defaults.string(forKey: TagColors.storageKey) ?? ""), ["job": 4])
    }

    func testOnlyANewCompletionReloadsHistory() {
        let running = task(status: .downloading)
        var done = running
        done.status = .completed
        XCTAssertTrue(AppViewModel.hasNewlyCompleted([done], previous: [running.id: .downloading]))
        XCTAssertFalse(AppViewModel.hasNewlyCompleted([done], previous: [running.id: .completed]))
        XCTAssertFalse(AppViewModel.hasNewlyCompleted([running], previous: [:]))
    }
}
