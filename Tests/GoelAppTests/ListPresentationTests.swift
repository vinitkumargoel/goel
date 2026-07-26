import XCTest
import GoelCore
@testable import GoelApp

/// Covers the adapter between the sidebar/sort chrome and the pure
/// ``TaskListQuery``.
///
/// The `.type` branch is the interesting one: it is the only caller of
/// `TaskListQuery.visible(…, extraMatch:)`, so nothing in GoelCoreTests reaches
/// it. If it regressed, a "by type" sidebar entry would show the wrong rows or
/// none — a silent presentation failure with no error path at all.
final class ListPresentationTests: XCTestCase {

    private func task(_ name: String,
                      status: DownloadStatus = .queued,
                      added: TimeInterval = 0,
                      size: Int64? = 100) -> DownloadTask {
        DownloadTask(
            source: .url(URL(string: "https://example.test/\(name)")!),
            name: name,
            saveDirectory: "/tmp",
            totalBytes: size,
            status: status,
            addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + added)
        )
    }

    private var sample: [DownloadTask] {
        [
            task("ubuntu.iso", status: .downloading, added: 1),
            task("clip.mkv", status: .paused, added: 2),
            task("backup.zip", status: .completed, added: 3),
            task("Tool.pkg", status: .seeding, added: 4),
            task("notes.txt", status: .queued, added: 5),
        ]
    }

    // MARK: the .type branch

    func testTypeFilterSelectsOnlyThatFileType() {
        let isos = ListPresentation.visible(
            tasks: sample, filter: .type(.iso), search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(isos.map(\.name), ["ubuntu.iso"])

        let docs = ListPresentation.visible(
            tasks: sample, filter: .type(.doc), search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(docs.map(\.name), ["notes.txt"])
    }

    /// A type filter must not quietly also filter by status: an .iso that is
    /// paused is still an .iso.
    func testTypeFilterIgnoresStatus() {
        let paused = task("disc.iso", status: .paused)
        let done = task("other.iso", status: .completed)
        let isos = ListPresentation.visible(
            tasks: [paused, done], filter: .type(.iso), search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(isos.count, 2)
    }

    func testTypeFilterStillHonoursSearch() {
        let both = [task("ubuntu.iso"), task("debian.iso")]
        let hits = ListPresentation.visible(
            tasks: both, filter: .type(.iso), search: "debian", sortKey: .name, ascending: true)
        XCTAssertEqual(hits.map(\.name), ["debian.iso"])
    }

    func testTypeCountMatchesWhatTheListShows() {
        for type in FileType.allCases {
            let shown = ListPresentation.visible(
                tasks: sample, filter: .type(type), search: "", sortKey: .name, ascending: true)
            XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .type(type)), shown.count,
                           "sidebar badge and list disagree for \(type)")
        }
    }

    func testMatchesAgreesWithTheTypeFilter() {
        let iso = task("ubuntu.iso")
        XCTAssertTrue(ListPresentation.matches(iso, filter: .type(.iso)))
        XCTAssertFalse(ListPresentation.matches(iso, filter: .type(.video)))
    }

    // MARK: the status branches

    func testStatusFiltersDelegateToTheCoreQuery() {
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .all), 5)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .paused), 1)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .completed), 1)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .seeding), 1)
    }

    // MARK: sorting

    func testCompareSortsByNameInBothDirections() {
        let a = task("alpha.bin")
        let b = task("beta.bin")
        XCTAssertTrue(ListPresentation.compare(a, b, key: .name, ascending: true))
        XCTAssertFalse(ListPresentation.compare(a, b, key: .name, ascending: false))
    }

    func testDescendingByAddedPutsTheNewestFirst() {
        let sorted = ListPresentation.visible(
            tasks: sample, filter: .all, search: "", sortKey: .added, ascending: false)
        XCTAssertEqual(sorted.first?.name, "notes.txt")
        XCTAssertEqual(sorted.last?.name, "ubuntu.iso")
    }

    /// Every `SortKey` the UI offers must map onto a core sort key. A missing
    /// case would silently sort by something else.
    func testEverySortKeyProducesAStableOrdering() {
        for key in SortKey.allCases {
            let ascending = ListPresentation.visible(
                tasks: sample, filter: .all, search: "", sortKey: key, ascending: true)
            let descending = ListPresentation.visible(
                tasks: sample, filter: .all, search: "", sortKey: key, ascending: false)
            XCTAssertEqual(ascending.count, sample.count, "\(key) dropped rows")
            XCTAssertEqual(descending.count, sample.count, "\(key) dropped rows")
        }
    }
}
