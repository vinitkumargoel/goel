import XCTest
@testable import GoelCore

final class QueueOrderTests: XCTestCase {

    private func task(_ name: String, position: Int? = nil, added: TimeInterval = 0,
                      status: DownloadStatus = .queued, priority: FilePriority = .normal) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                     name: name, saveDirectory: "/tmp",
                     totalBytes: 100, status: status, priority: priority,
                     addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + added),
                     queuePosition: position)
    }

    private func names(_ tasks: [DownloadTask]) -> [String] { QueueOrder.sorted(tasks).map(\.name) }

    // MARK: - Ordering

    func testPositionWinsOverAddedDate() {
        let tasks = [task("a", position: 2, added: 1), task("b", position: 0, added: 2), task("c", position: 1, added: 3)]
        XCTAssertEqual(names(tasks), ["b", "c", "a"])
    }

    func testUnnumberedRowsSortAfterNumberedOnesByAddedDate() {
        let tasks = [task("late", added: 9), task("numbered", position: 5, added: 10), task("early", added: 1)]
        XCTAssertEqual(names(tasks), ["numbered", "early", "late"])
    }

    func testRanksAreDenseAndOneBasedDespiteGaps() {
        let a = task("a", position: 3), b = task("b", position: 40), c = task("c", position: 7)
        let ranks = QueueOrder.ranks([a, b, c])
        XCTAssertEqual(ranks[a.id], 1)
        XCTAssertEqual(ranks[c.id], 2)
        XCTAssertEqual(ranks[b.id], 3)
    }

    func testNextPositionIsTheBackOfTheLineAndSaturates() {
        XCTAssertEqual(QueueOrder.nextPosition(in: []), 0)
        XCTAssertEqual(QueueOrder.nextPosition(in: [task("a", position: 4), task("b")]), 5)
        XCTAssertEqual(QueueOrder.nextPosition(in: [task("a", position: .max)]), .max)
    }

    // MARK: - Migration

    func testBackfillNumbersLegacyRowsInArrayOrderAfterExistingOnes() {
        let legacy1 = task("old1", added: 1), legacy2 = task("old2", added: 2)
        let numbered = task("new", position: 0, added: 3)
        let out = QueueOrder.backfilled([legacy1, legacy2, numbered])
        XCTAssertEqual(out.map(\.queuePosition), [1, 2, 0])
        XCTAssertEqual(out.map(\.id), [legacy1.id, legacy2.id, numbered.id], "array order is kept")
    }

    func testBackfillLeavesAFullyNumberedQueueUntouched() {
        let tasks = [task("a", position: 1), task("b", position: 0)]
        XCTAssertEqual(QueueOrder.backfilled(tasks), tasks)
    }

    func testBackfillRenumbersOutOfRangePositions() {
        let out = QueueOrder.backfilled([task("a", position: 0), task("b", position: -5), task("c", position: .max)])
        XCTAssertEqual(out.map(\.queuePosition), [0, 1, 2])
    }

    // MARK: - Moving

    private var abcd: [DownloadTask] {
        [task("a", position: 0), task("b", position: 1), task("c", position: 2), task("d", position: 3)]
    }

    private func id(_ name: String, in tasks: [DownloadTask]) -> UUID { tasks.first { $0.name == name }!.id }

    func testMoveToTopAndBottom() {
        let tasks = abcd
        XCTAssertEqual(names(QueueOrder.moving([id("c", in: tasks)], to: .top, in: tasks)), ["c", "a", "b", "d"])
        XCTAssertEqual(names(QueueOrder.moving([id("a", in: tasks)], to: .bottom, in: tasks)), ["b", "c", "d", "a"])
    }

    func testMultiRowMoveKeepsTheRowsRelativeOrderWhateverOrderTheIdsCameIn() {
        let tasks = abcd
        let moved = QueueOrder.moving([id("d", in: tasks), id("b", in: tasks)], to: .top, in: tasks)
        XCTAssertEqual(names(moved), ["b", "d", "a", "c"])
    }

    func testMoveBeforeAndAfterAnAnchor() {
        let tasks = abcd
        XCTAssertEqual(names(QueueOrder.moving([id("d", in: tasks)], to: .before(id("b", in: tasks)), in: tasks)),
                       ["a", "d", "b", "c"])
        XCTAssertEqual(names(QueueOrder.moving([id("a", in: tasks)], to: .after(id("c", in: tasks)), in: tasks)),
                       ["b", "c", "a", "d"])
    }

    func testAnchorThatIsItselfMovingFallsBackToTheEnd() {
        let tasks = abcd
        let a = id("a", in: tasks), b = id("b", in: tasks)
        XCTAssertEqual(names(QueueOrder.moving([a, b], to: .before(a), in: tasks)), ["c", "d", "a", "b"])
    }

    func testMoveRenumbersDenselyAndKeepsArrayOrder() {
        let tasks = [task("a", position: 10), task("b", position: 30), task("c", position: 20)]
        let moved = QueueOrder.moving([tasks[1].id], to: .top, in: tasks)
        XCTAssertEqual(moved.map(\.id), tasks.map(\.id))
        XCTAssertEqual(moved.map(\.queuePosition), [1, 0, 2])
    }

    func testMovingNothingOrUnknownIdsChangesNothing() {
        let tasks = abcd
        XCTAssertEqual(QueueOrder.moving([], to: .top, in: tasks), tasks)
        XCTAssertEqual(QueueOrder.moving([UUID()], to: .top, in: tasks), tasks)
    }

    // MARK: - Scheduling and the list

    func testSchedulerStartsQueuedRowsInQueueOrderWithinAPriority() {
        let a = task("a", position: 2, added: 1)
        let b = task("b", position: 0, added: 2)
        let c = task("c", position: 1, added: 3, priority: .high)
        let promoted = SchedulingPolicy.promotions(tasks: [a, b, c], runningSlots: [],
                                                   maxSimultaneousDownloads: 10,
                                                   maxMetadataResolutions: 10, windowOpen: true)
        XCTAssertEqual(promoted, [c.id, b.id, a.id], "priority first, then queue position — not addedAt")
    }

    func testIndexSortIsQueueOrder() {
        let tasks = [task("a", position: 1, added: 1), task("b", position: 0, added: 2)]
        let sorted = TaskListQuery.visible(tasks: tasks, filter: .all, search: "", sortKey: .index, ascending: true)
        XCTAssertEqual(sorted.map(\.name), ["b", "a"])
    }

    // MARK: - Persistence

    func testQueuePositionSurvivesACodableRoundTrip() throws {
        let original = task("a", position: 7)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.queuePosition, 7)
    }

    func testRowSavedBeforeQueuePositionsDecodesWithNone() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task("a", position: 3)))
                                 as? [String: Any])
        json.removeValue(forKey: "queuePosition")
        let legacy = try JSONDecoder().decode(DownloadTask.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.queuePosition)
    }

    func testQueuePositionSurvivesTheStore() throws {
        let store = try PersistenceStore()
        let tasks = [task("a", position: 1, added: 1), task("b", position: 0, added: 2)]
        try store.saveTasks(tasks)
        let reloaded = try store.loadAllTasks()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reloaded.map { ($0.name, $0.queuePosition) }),
                       ["a": 1, "b": 0])
    }

    // MARK: - Manager

    func testManagerNumbersAddsAndReordersTheQueue() async {
        let manager = DownloadManager(httpEngine: FakeEngine(kind: .http), torrentEngine: FakeEngine(kind: .torrent))
        let a = await manager.add(source: .url(URL(string: "https://example.test/a.bin")!), startPaused: true)
        let b = await manager.add(source: .url(URL(string: "https://example.test/b.bin")!), startPaused: true)
        let c = await manager.add(source: .url(URL(string: "https://example.test/c.bin")!), startPaused: true)
        XCTAssertEqual([a, b, c].map(\.queuePosition), [0, 1, 2], "each add joins the back of the line")

        await manager.moveInQueue([c.id], to: .top)
        let order = QueueOrder.sorted(await manager.snapshot).map(\.id)
        XCTAssertEqual(order, [c.id, a.id, b.id])
    }
}
