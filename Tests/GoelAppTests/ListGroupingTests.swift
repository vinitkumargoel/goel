import XCTest
import GoelCore
@testable import GoelApp

/// Group by, the Queued and tag filters, and the sidebar catalogue — the pure parts of the list.
final class ListGroupingTests: XCTestCase {

    /// A fixed Gregorian calendar, weeks starting Monday, so buckets don't depend on the test machine.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    /// Thursday 17 September 2026, 15:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 15))!
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func task(_ name: String, status: DownloadStatus = .queued, added: Date? = nil,
                      size: Int64? = 100, tags: [String]? = nil, label: String? = nil) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!), name: name,
                     saveDirectory: "/tmp", totalBytes: size, status: status,
                     addedAt: added ?? now, label: label, tags: tags)
    }

    // MARK: - Date buckets

    func testDateBuckets() {
        func bucket(_ date: Date) -> DateBucket { DateBucket.bucket(for: date, now: now, calendar: calendar) }
        XCTAssertEqual(bucket(now.addingTimeInterval(-60)), .today)
        XCTAssertEqual(bucket(now.addingTimeInterval(3_600)), .today, "a future date is not lost")
        XCTAssertEqual(bucket(daysAgo(1)), .yesterday)
        XCTAssertEqual(bucket(daysAgo(3)), .thisWeek, "Monday of the same week")
        XCTAssertEqual(bucket(daysAgo(10)), .thisMonth, "7 September")
        XCTAssertEqual(bucket(daysAgo(20)), .older, "late August")
    }

    func testYesterdayWinsWhenItFallsInLastWeek() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9))!
        let sunday = monday.addingTimeInterval(-86_400)
        XCTAssertEqual(DateBucket.bucket(for: sunday, now: monday, calendar: calendar), .yesterday)
    }

    func testSectionsByDateKeepTheSortInsideEachBucketAndSkipEmptyOnes() {
        let sorted = [task("b", added: daysAgo(20)), task("a", added: now), task("c", added: daysAgo(20.5))]
        let sections = ListPresentation.sections(sorted, by: .date, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), [DateBucket.today.title, DateBucket.older.title])
        XCTAssertEqual(sections[1].tasks.map(\.name), ["b", "c"], "the list's own sort is kept")
    }

    // MARK: - Status and type

    func testSectionsByStatusPutWorkInProgressFirst() {
        let sorted = [task("done", status: .completed), task("wait", status: .queued),
                      task("run", status: .downloading), task("meta", status: .requestingMetadata)]
        let sections = ListPresentation.sections(sorted, by: .status, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.id), ["status.0", "status.2", "status.5"])
        XCTAssertEqual(sections[0].tasks.map(\.name), ["run", "meta"])
    }

    func testSectionsByTypeFollowTheSidebarOrder() {
        let sorted = [task("a.zip"), task("b.mp3"), task("c.mkv")]
        let sections = ListPresentation.sections(sorted, by: .type, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), [FileType.video, .audio, .archive].map(\.accessibilityName))
    }

    func testSectionTotalsCountKnownSizesOnly() {
        let section = ListSection(id: "x", title: "", tasks: [task("a", size: 100), task("b", size: nil),
                                                                task("c", size: 50)])
        XCTAssertEqual(section.totalBytes, 150)
    }

    func testNoGroupingIsOneSectionOrNone() {
        XCTAssertEqual(ListPresentation.sections([], by: .none).count, 0)
        XCTAssertEqual(ListPresentation.sections([task("a")], by: .none).map(\.tasks.count), [1])
    }

    func testGroupingRoundTripsThroughItsStoredValue() {
        for grouping in ListGrouping.allCases {
            XCTAssertEqual(ListGrouping(rawValue: grouping.rawValue), grouping)
            XCTAssertFalse(grouping.title.isEmpty)
        }
    }

    // MARK: - Queued and tag filters

    func testQueuedFilterIsOnlyRowsWaitingForASlot() {
        let tasks = [task("a", status: .queued), task("b", status: .paused), task("c", status: .downloading)]
        XCTAssertEqual(ListPresentation.visible(tasks: tasks, filter: .queued, search: "",
                                                sortKey: .name, ascending: true).map(\.name), ["a"])
        XCTAssertEqual(ListPresentation.count(tasks: tasks, filter: .queued), 1)
    }

    func testTagFilterIsCaseInsensitiveAndIncludesTheLegacyLabel() {
        let tasks = [task("a", tags: ["Work"]), task("b", label: "work"), task("c", tags: ["home"])]
        let hits = ListPresentation.visible(tasks: tasks, filter: .tag("WORK"), search: "",
                                            sortKey: .name, ascending: true)
        XCTAssertEqual(hits.map(\.name), ["a", "b"])
        XCTAssertEqual(ListPresentation.count(tasks: tasks, filter: .tag("work")), 2)
    }

    func testTagCountsMergeCaseAndSortAlphabetically() {
        let tasks = [task("a", tags: ["Work", "linux"]), task("b", tags: ["work"]), task("c")]
        let counts = ListPresentation.tagCounts(tasks)
        XCTAssertEqual(counts.map(\.tag), ["linux", "Work"])
        XCTAssertEqual(counts.map(\.count), [1, 2])
    }

    func testTagColourIsStableAndInRange() {
        let slot = ListPresentation.tagColorSlot("Work", slots: 8)
        XCTAssertEqual(ListPresentation.tagColorSlot("work", slots: 8), slot, "case does not change the colour")
        XCTAssertEqual(slot, 0, "FNV-1a of \"work\" — fixed, so a tag keeps its colour across launches")
        for tag in ["a", "linux", "Ünïcødé", ""] {
            XCTAssertTrue((0..<8).contains(ListPresentation.tagColorSlot(tag, slots: 8)))
        }
        XCTAssertEqual(ListPresentation.tagColorSlot("x", slots: 0), 0)
    }

    // MARK: - Sidebar catalogue

    func testShortcutsCountDownTheSidebarAsDrawn() {
        let shortcuts = SidebarCatalog.shortcutFilters
        XCTAssertEqual(shortcuts.count, 9)
        XCTAssertEqual(Array(shortcuts.prefix(3)), [.all, .active, .queued])
        XCTAssertEqual(shortcuts, Array(SidebarCatalog.all.prefix(9).map(\.filter)))
    }

    func testSidebarOffersTheNewTypesAndNoDuplicates() {
        let filters = SidebarCatalog.all.map(\.filter)
        XCTAssertEqual(Set(filters).count, filters.count)
        for type in [FileType.audio, .image, .doc, .other] {
            XCTAssertTrue(filters.contains(.type(type)), "\(type)")
        }
        XCTAssertFalse(filters.contains(.type(.magnet)))
        XCTAssertEqual(Set(SidebarCatalog.all.map(\.id)).count, filters.count, "ids are unique")
    }
}
