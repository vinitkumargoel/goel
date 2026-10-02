import XCTest
import GoelCore
@testable import GoelApp

private func task(_ name: String = "a.bin", status: DownloadStatus, missing: Bool = false,
                  completedAt: Date? = nil, addedAt: Date = Date()) -> DownloadTask {
    var t = DownloadTask(source: .url(URL(string: "https://e.test/\(name)")!), name: name,
                         saveDirectory: "/tmp", totalBytes: 1_000, status: status, addedAt: addedAt)
    t.fileMissing = missing ? true : nil
    t.completedAt = completedAt
    return t
}

final class DownloadBoardLanesTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue 14 Nov 2023, 22:13 UTC

    func testEveryStateLandsInExactlyOneLane() {
        XCTAssertEqual(BoardLaneKind(task: task(status: .downloading)), .downloading)
        XCTAssertEqual(BoardLaneKind(task: task(status: .verifying)), .downloading)
        XCTAssertEqual(BoardLaneKind(task: task(status: .requestingMetadata)), .downloading)
        XCTAssertEqual(BoardLaneKind(task: task(status: .queued)), .upNext)
        XCTAssertEqual(BoardLaneKind(task: task(status: .paused)), .needsYou)
        XCTAssertEqual(BoardLaneKind(task: task(status: .failed(.httpStatus(404)))), .needsYou)
        XCTAssertEqual(BoardLaneKind(task: task(status: .completed, missing: true)), .needsYou)
        XCTAssertEqual(BoardLaneKind(task: task(status: .completed)), .done)
        XCTAssertEqual(BoardLaneKind(task: task(status: .seeding)), .done)
    }

    func testEmptyLanesAreLeftOutAndOrderIsFixed() {
        let lanes = BoardLanes.statusLanes([task(status: .completed), task(status: .downloading)], ranks: [:],
                                           now: now, calendar: calendar)
        XCTAssertEqual(lanes.map(\.kind), [.downloading, .done])
        XCTAssertTrue(BoardLanes.statusLanes([], ranks: [:]).isEmpty)
    }

    func testUpNextFollowsTheQueueNotTheSort() {
        let a = task("a", status: .queued), b = task("b", status: .queued), c = task("c", status: .queued)
        let lanes = BoardLanes.statusLanes([a, b, c], ranks: [a.id: 3, b.id: 1], now: now, calendar: calendar)
        XCTAssertEqual(lanes.first?.tasks.map(\.name), ["b", "a", "c"], "unranked rows go last")
    }

    func testDoneSaysTodayOnlyWhenEveryCardFinishedToday() {
        let today = task(status: .completed, completedAt: now.addingTimeInterval(-600))
        let older = task(status: .completed, completedAt: now.addingTimeInterval(-3 * 86_400))
        XCTAssertTrue(BoardLanes.allFinishedToday([today], now: now, calendar: calendar))
        XCTAssertFalse(BoardLanes.allFinishedToday([today, older], now: now, calendar: calendar))
        XCTAssertEqual(BoardLanes.title(.done, tasks: [today], now: now, calendar: calendar), "Done today")
        XCTAssertEqual(BoardLanes.title(.done, tasks: [today, older], now: now, calendar: calendar), "Done")
    }

    func testGroupByLanesTheSections() {
        let a = task("a.mp4", status: .completed), b = task("b.zip", status: .queued)
        let sections = [ListSection(id: "type.video", title: "Video", tasks: [a]),
                        ListSection(id: "type.archive", title: "Archives", tasks: [b])]
        let lanes = BoardLanes.make(visible: [a, b], sections: sections, grouping: .type, ranks: [:])
        XCTAssertEqual(lanes.map(\.title), ["Video", "Archives"])
        XCTAssertTrue(lanes.allSatisfy { $0.kind == nil })
    }

    func testCardStyle() {
        XCTAssertEqual(BoardCardStyle(task: task(status: .downloading)), .large)
        XCTAssertEqual(BoardCardStyle(task: task(status: .verifying)), .large)
        XCTAssertEqual(BoardCardStyle(task: task(status: .requestingMetadata)), .compact)
        XCTAssertEqual(BoardCardStyle(task: task(status: .paused)), .compact)
    }

    func testColumnsKeepReadingOrderAndBalanceHeight() {
        // Four lanes in three columns: the two short middle lanes share a column, as in the mockup.
        XCTAssertEqual(BoardLanes.columns(heights: [400, 150, 150, 350], count: 3, stackGap: 0), [[0], [1, 2], [3]])
        XCTAssertEqual(BoardLanes.columns(heights: [100, 100], count: 4), [[0], [1]])
        XCTAssertEqual(BoardLanes.columns(heights: [100, 100, 100], count: 1), [[0, 1, 2]])
        XCTAssertEqual(BoardLanes.columns(heights: [], count: 3), [])
        let split = BoardLanes.columns(heights: [10, 20, 30, 40, 50], count: 2)
        XCTAssertEqual(split.flatMap { $0 }, [0, 1, 2, 3, 4])
    }

    func testColumnCountFollowsWidth() {
        XCTAssertEqual(BoardLanes.columnCount(width: 0, laneCount: 4, gap: 18), 4)
        XCTAssertEqual(BoardLanes.columnCount(width: 2000, laneCount: 4, gap: 18), 4)
        XCTAssertEqual(BoardLanes.columnCount(width: 780, laneCount: 4, gap: 18), 3)
        XCTAssertEqual(BoardLanes.columnCount(width: 100, laneCount: 4, gap: 18), 1)
        XCTAssertEqual(BoardLanes.columnCount(width: 900, laneCount: 0, gap: 18), 0)
    }

    func testLeftAndRightMoveAcrossLanesAtTheSameHeight() {
        let d1 = task("d1", status: .downloading), d2 = task("d2", status: .downloading)
        let q1 = task("q1", status: .queued)
        let lanes = BoardLanes.statusLanes([d1, d2, q1], ranks: [:])
        XCTAssertEqual(BoardLanes.laneNeighbor(in: lanes, from: d2.id, step: 1), q1.id, "clamped to the lane's last card")
        XCTAssertEqual(BoardLanes.laneNeighbor(in: lanes, from: q1.id, step: -1), d1.id)
        XCTAssertEqual(BoardLanes.laneNeighbor(in: lanes, from: q1.id, step: 1), q1.id, "no lane further right")
        XCTAssertEqual(BoardLanes.laneNeighbor(in: lanes, from: nil, step: 1), d1.id)
        XCTAssertEqual(BoardLanes.flattened(lanes).map(\.name), ["d1", "d2", "q1"])
    }

    func testCardMetaByState() {
        let queued = DownloadCardText.compactMeta(task(status: .queued), speed: .zero, queueRank: 2)
        XCTAssertTrue(queued.text.hasPrefix("HTTP · "), queued.text)
        XCTAssertTrue(queued.text.hasSuffix("#2"), queued.text)
        XCTAssertEqual(DownloadCardText.compactMeta(task(status: .failed(.network("boom"))), speed: .zero,
                                                    queueRank: nil).tone, .bad)
        XCTAssertEqual(DownloadCardText.compactMeta(task(status: .completed, missing: true), speed: .zero,
                                                    queueRank: nil).tone, .warn)
        var seeding = task(status: .seeding)
        seeding.seedRatioLimit = 2
        let seed = DownloadCardText.compactMeta(seeding, speed: SpeedSample(down: 0, up: 2_000_000), queueRank: nil)
        XCTAssertEqual(seed.tone, .upload)
        XCTAssertTrue(seed.text.contains("of 2.00×") && seed.text.contains("↑ "), seed.text)
        XCTAssertEqual(DownloadCardText.largeTrailing(task(status: .verifying)), "Verifying…")
    }
}
