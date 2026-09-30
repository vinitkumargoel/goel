import XCTest
@testable import GoelCore

final class TaskListQueryTests: XCTestCase {

    private func task(
        _ name: String,
        status: DownloadStatus,
        added: TimeInterval,
        size: Int64? = 100,
        down: Double = 0,
        up: Double = 0,
        tags: [String] = [],
        note: String? = nil
    ) -> DownloadTask {
        return DownloadTask(
            source: .url(URL(string: "https://example.test/\(name)")!),
            name: name,
            saveDirectory: "/tmp",
            totalBytes: size,
            downloadSpeed: down,
            uploadSpeed: up,
            status: status,
            addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + added),
            tags: tags.isEmpty ? nil : tags,
            note: note
        )
    }

    func testFilterStatus() {
        let tasks = [
            task("a", status: .downloading, added: 1),
            task("b", status: .paused, added: 2),
            task("c", status: .completed, added: 3),
            task("d", status: .seeding, added: 4),
            task("e", status: .queued, added: 5),
        ]
        XCTAssertEqual(TaskListQuery.count(tasks: tasks, filter: .all), 5)
        XCTAssertEqual(TaskListQuery.count(tasks: tasks, filter: .paused), 1)
        XCTAssertEqual(TaskListQuery.count(tasks: tasks, filter: .completed), 1)
        XCTAssertEqual(TaskListQuery.count(tasks: tasks, filter: .seeding), 1)
        let active = TaskListQuery.visible(
            tasks: tasks, filter: .active, search: "", sortKey: .name, ascending: true)
        XCTAssertTrue(active.allSatisfy { $0.status.isActive })
        XCTAssertEqual(Set(active.map(\.name)), Set(["a", "d"]))
    }

    func testSearchNameTagsNote() {
        let tasks = [
            task("Movie.mkv", status: .queued, added: 1, tags: ["film"]),
            task("Archive.zip", status: .queued, added: 2, note: "backup nightly"),
            task("Other.bin", status: .queued, added: 3),
        ]
        XCTAssertEqual(
            TaskListQuery.visible(tasks: tasks, filter: .all, search: "movie",
                                  sortKey: .name, ascending: true).map(\.name),
            ["Movie.mkv"])
        XCTAssertEqual(
            TaskListQuery.visible(tasks: tasks, filter: .all, search: "film",
                                  sortKey: .name, ascending: true).map(\.name),
            ["Movie.mkv"])
        XCTAssertEqual(
            TaskListQuery.visible(tasks: tasks, filter: .all, search: "nightly",
                                  sortKey: .name, ascending: true).map(\.name),
            ["Archive.zip"])
    }

    func testSortByStatusAndName() {
        let tasks = [
            task("z", status: .completed, added: 1),
            task("a", status: .downloading, added: 2),
            task("m", status: .paused, added: 3),
        ]
        let byStatus = TaskListQuery.visible(
            tasks: tasks, filter: .all, search: "", sortKey: .status, ascending: true)
        XCTAssertEqual(byStatus.map(\.status), [.downloading, .paused, .completed])

        let byName = TaskListQuery.visible(
            tasks: tasks, filter: .all, search: "", sortKey: .name, ascending: true)
        XCTAssertEqual(byName.map(\.name), ["a", "m", "z"])

        let byNameDesc = TaskListQuery.visible(
            tasks: tasks, filter: .all, search: "", sortKey: .name, ascending: false)
        XCTAssertEqual(byNameDesc.map(\.name), ["z", "m", "a"])
    }

    func testStatusOrderRanks() {
        XCTAssertEqual(TaskListQuery.statusOrder(.downloading), 0)
        XCTAssertEqual(TaskListQuery.statusOrder(.verifying), 0)
        XCTAssertLessThan(TaskListQuery.statusOrder(.downloading),
                          TaskListQuery.statusOrder(.queued))
        XCTAssertLessThan(TaskListQuery.statusOrder(.queued),
                          TaskListQuery.statusOrder(.completed))
    }

    // MARK: - Search

    private func hosted(_ name: String, _ url: String, label: String? = nil) -> DownloadTask {
        DownloadTask(source: .url(URL(string: url)!), name: name, saveDirectory: "/tmp", label: label)
    }

    private var hostedSample: [DownloadTask] {
        [
            hosted("ubuntu.iso", "https://releases.ubuntu.com/24.04/ubuntu.iso"),
            hosted("model.bin", "https://cdn.huggingface.co/x/model.bin?rev=abc123"),
            hosted("notes.pdf", "https://files.example.org/notes.pdf", label: "Work"),
            DownloadTask(source: .magnet("magnet:?xt=urn:btih:ffff"), name: "Pack", saveDirectory: "/tmp"),
        ]
    }

    private func search(_ q: String) -> [String] {
        TaskListQuery.visible(tasks: hostedSample, filter: .all, search: q, sortKey: .name, ascending: true)
            .map(\.name)
    }

    func testSearchParsesHostTokensOutOfThePhrase() {
        let q = TaskListQuery.Search("  host:GitHub.com   release  notes ")
        XCTAssertEqual(q.hosts, ["github.com"])
        XCTAssertEqual(q.text, "release notes")
    }

    func testPlainSearchKeepsItsSpacingAndIsCaseInsensitive() {
        let q = TaskListQuery.Search("  Big  File ")
        XCTAssertEqual(q.hosts, [])
        XCTAssertEqual(q.text, "big  file")
    }

    func testABareHostPrefixNarrowsNothing() {
        let q = TaskListQuery.Search("host:")
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(search("host:"), ["model.bin", "notes.pdf", "Pack", "ubuntu.iso"])
    }

    func testSearchMatchesTheSourceHostAndURL() {
        XCTAssertEqual(search("huggingface"), ["model.bin"])
        XCTAssertEqual(search("rev=abc123"), ["model.bin"], "a pasted URL fragment finds its row")
        XCTAssertEqual(search("24.04"), ["ubuntu.iso"])
    }

    func testSearchMatchesTheLabel() {
        XCTAssertEqual(search("work"), ["notes.pdf"])
    }

    func testHostTokenNarrowsToThatHostAndCombinesWithText() {
        XCTAssertEqual(search("host:ubuntu.com"), ["ubuntu.iso"])
        XCTAssertEqual(search("host:example.org notes"), ["notes.pdf"])
        XCTAssertEqual(search("host:example.org ubuntu"), [])
        XCTAssertEqual(search("host:example.org host:ubuntu"), [], "every host token must match")
    }

    func testHostTokenNeverMatchesAMagnet() {
        XCTAssertFalse(search("host:btih").contains("Pack"))
    }
}
