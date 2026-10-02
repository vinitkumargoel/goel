import XCTest
import GoelCore
@testable import GoelApp

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

    func testTypeFilterSelectsOnlyThatFileType() {
        let isos = ListPresentation.visible(
            tasks: sample, filter: .type(.iso), search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(isos.map(\.name), ["ubuntu.iso"])

        let docs = ListPresentation.visible(
            tasks: sample, filter: .type(.doc), search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(docs.map(\.name), ["notes.txt"])
    }

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

    func testStatusFiltersDelegateToTheCoreQuery() {
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .all), 5)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .paused), 1)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .completed), 1)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .seeding), 1)
    }

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

    private func moving(_ name: String, total: Int64?, done: Int64, speed: Double,
                        status: DownloadStatus = .downloading) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!), name: name,
                     saveDirectory: "/tmp", totalBytes: total, bytesDownloaded: done,
                     downloadSpeed: speed, status: status)
    }

    /// ETA, Progress and Remaining sort the list; rows without an ETA or a size sort as "longest".
    func testSortsByEtaProgressAndRemaining() {
        let soon = moving("soon", total: 1_000, done: 900, speed: 100)      // 1 s, 90 %, 100 B
        let later = moving("later", total: 10_000, done: 5_000, speed: 100) // 50 s, 50 %, 5000 B
        let stalled = moving("stalled", total: 1_000, done: 200, speed: 0, status: .paused) // no ETA
        let unknown = moving("unknown", total: nil, done: 0, speed: 0, status: .queued)
        let list = [stalled, later, unknown, soon]
        func order(_ key: SortKey, ascending: Bool = true) -> [String] {
            ListPresentation.visible(tasks: list, filter: .all, search: "", sortKey: key, ascending: ascending)
                .map(\.name)
        }
        XCTAssertEqual(Array(order(.eta).prefix(2)), ["soon", "later"])
        XCTAssertEqual(order(.progress, ascending: false).first, "soon")
        XCTAssertEqual(order(.progress).first, "unknown")
        XCTAssertEqual(order(.remaining), ["soon", "stalled", "later", "unknown"])
    }

    func testSortsByRatioAndPeersWithNonTorrentsLast() {
        var seeded = moving("seeded", total: 1_000, done: 1_000, speed: 0, status: .seeding)
        seeded.bytesUploaded = 3_000
        var torrent = DownloadTask(source: .magnet("magnet:?xt=urn:btih:abc"), name: "swarm",
                                   saveDirectory: "/tmp", totalBytes: 1_000, bytesDownloaded: 1_000,
                                   status: .seeding)
        torrent.bytesUploaded = 500
        torrent.connectionCount = 12
        torrent.seedCount = 4
        let http = moving("plain", total: 1_000, done: 1_000, speed: 0, status: .completed)
        let ratio = ListPresentation.visible(tasks: [http, torrent, seeded], filter: .all, search: "",
                                             sortKey: .ratio, ascending: false).map(\.name)
        XCTAssertEqual(ratio.first, "swarm", "a plain download's ratio means nothing, so it sorts below")
        let peers = ListPresentation.visible(tasks: [http, torrent], filter: .all, search: "",
                                             sortKey: .peers, ascending: false).map(\.name)
        XCTAssertEqual(peers, ["swarm", "plain"])
    }

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

    func testFailedFilterSelectsOnlyFailedDownloads() {
        let broken = task("broken.iso", status: .failed(.httpStatus(403)), added: 6)
        let list = sample + [broken]
        let failed = ListPresentation.visible(
            tasks: list, filter: .failed, search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(failed.map(\.name), ["broken.iso"])
        XCTAssertTrue(ListPresentation.matches(broken, filter: .failed))
        XCTAssertFalse(ListPresentation.matches(sample[0], filter: .failed))
    }

    func testFailedFilterHonoursSearchAndCount() {
        let list = [task("a.iso", status: .failed(.httpStatus(404))),
                    task("b.iso", status: .failed(.httpStatus(500))),
                    task("c.iso", status: .paused)]
        let hits = ListPresentation.visible(
            tasks: list, filter: .failed, search: "b.", sortKey: .name, ascending: true)
        XCTAssertEqual(hits.map(\.name), ["b.iso"])
        XCTAssertEqual(ListPresentation.count(tasks: list, filter: .failed), 2)
        XCTAssertEqual(ListPresentation.count(tasks: sample, filter: .failed), 0)
    }
}
