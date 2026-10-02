import XCTest
import GoelCore
@testable import GoelApp

final class DownloadFiltersTests: XCTestCase {

    private func task(_ name: String, status: DownloadStatus = .queued, tags: [String]? = nil) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!), name: name,
                             saveDirectory: "/tmp", totalBytes: 100, status: status)
        t.tags = tags
        return t
    }

    private var sample: [DownloadTask] {
        [
            task("song.flac", status: .downloading, tags: ["Work"]),
            task("album.mp3", status: .completed),
            task("movie.mkv", status: .downloading, tags: ["work"]),
            task("podcast.m4a", status: .paused, tags: ["home"]),
        ]
    }

    private func names(_ filters: DownloadFilters, search: String = "") -> [String] {
        ListPresentation.visible(tasks: sample, filters: filters, search: search, sortKey: .name, ascending: true)
            .map(\.name)
    }

    func testAxesAreIndependentAndAnded() {
        var filters = DownloadFilters()
        filters = filters.setting(.active)
        filters = filters.setting(.type(.audio))
        XCTAssertEqual(filters.status, .active, "picking a type keeps the status")
        XCTAssertEqual(filters.type, .audio)
        XCTAssertEqual(names(filters), ["song.flac"])

        filters = filters.setting(.tag("WORK"))
        XCTAssertEqual(filters.type, .audio, "picking a tag keeps the type")
        XCTAssertEqual(names(filters), ["song.flac"])

        filters = filters.setting(.completed)
        XCTAssertEqual(filters.type, .audio, "picking a status keeps the type")
        XCTAssertEqual(names(filters), [])
    }

    func testAllClearsOnlyTheStatusAxis() {
        let filters = DownloadFilters(status: .paused, type: .audio, tag: "home").setting(.all)
        XCTAssertEqual(filters, DownloadFilters(status: .all, type: .audio, tag: "home"))
        XCTAssertFalse(filters.isEmpty)
        XCTAssertTrue(DownloadFilters().isEmpty)
    }

    func testIsOnPerAxis() {
        let filters = DownloadFilters(status: .active, type: .audio, tag: "Work")
        XCTAssertTrue(filters.isOn(.active))
        XCTAssertFalse(filters.isOn(.all))
        XCTAssertTrue(filters.isOn(.type(.audio)))
        XCTAssertFalse(filters.isOn(.type(.video)))
        XCTAssertTrue(filters.isOn(.tag("work")), "tags compare case-insensitively")
        XCTAssertTrue(DownloadFilters().isOn(.all))
    }

    func testPrimaryIsTheNarrowestAxisForOlderCallers() {
        XCTAssertEqual(DownloadFilters().primary, .all)
        XCTAssertEqual(DownloadFilters(status: .failed).primary, .failed)
        XCTAssertEqual(DownloadFilters(status: .failed, type: .video).primary, .type(.video))
        XCTAssertEqual(DownloadFilters(status: .failed, type: .video, tag: "x").primary, .tag("x"))
    }

    func testSingleFilterOverloadStillMatchesItsAxis() {
        XCTAssertEqual(ListPresentation.visible(tasks: sample, filter: .type(.audio), search: "",
                                                sortKey: .name, ascending: true).count, 3)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filters: DownloadFilters(status: .active, type: .audio)), 1)
    }

    func testSearchStillNarrowsCombinedFilters() {
        XCTAssertEqual(names(DownloadFilters(type: .audio), search: "pod"), ["podcast.m4a"])
    }

    func testRetaggingFollowsTheTagAxis() {
        let filters = DownloadFilters(status: .active, tag: "Work")
        XCTAssertEqual(filters.renamingTag("work", to: "Job").tag, "Job")
        XCTAssertEqual(filters.renamingTag("home", to: "Job").tag, "Work")
        XCTAssertNil(filters.removingTag("WORK").tag)
        XCTAssertEqual(filters.removingTag("WORK").status, .active)
    }
}

final class SelectionPruneTests: XCTestCase {

    func testHiddenRowsLeaveTheSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        let kept = SelectionRange.pruned(selection: [a, b], primary: b, anchor: a, visible: [a, c])
        XCTAssertEqual(kept.selection, [a])
        XCTAssertEqual(kept.primary, a, "the detail moves to a row that is still shown")
        XCTAssertEqual(kept.anchor, a)
    }

    func testEverythingHiddenClearsTheDetail() {
        let a = UUID(), c = UUID()
        let kept = SelectionRange.pruned(selection: [a], primary: a, anchor: a, visible: [c])
        XCTAssertEqual(kept.selection, [])
        XCTAssertNil(kept.primary)
        XCTAssertNil(kept.anchor)
    }

    func testAVisibleSelectionIsUntouched() {
        let a = UUID(), b = UUID()
        let kept = SelectionRange.pruned(selection: [a, b], primary: b, anchor: a, visible: [a, b])
        XCTAssertEqual(kept.selection, [a, b])
        XCTAssertEqual(kept.primary, b)
        XCTAssertEqual(kept.anchor, a)
    }
}
