import XCTest
import GoelCore
@testable import GoelApp

final class SelectionAggregateTests: XCTestCase {

    private func task(_ name: String, total: Int64?, done: Int64, status: DownloadStatus,
                      down: Double = 0) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                             name: name, saveDirectory: "/tmp", totalBytes: total,
                             downloadSpeed: down, status: status)
        t.bytesDownloaded = done
        return t
    }

    private func aggregate(_ tasks: [DownloadTask]) -> SelectionAggregate {
        SelectionAggregate(tasks: tasks) { SpeedSample(down: $0.downloadSpeed, up: $0.uploadSpeed) }
    }

    func testProgressIsWeightedByBytesNotAveragedPerRow() {
        let big = task("big.iso", total: 4_000, done: 2_000, status: .downloading)
        let small = task("small.txt", total: 10, done: 10, status: .completed)
        let summary = aggregate([big, small])
        XCTAssertEqual(summary.fraction, 2_010.0 / 4_010.0, accuracy: 0.0001)
    }

    func testRowsWithoutASizeFallBackToTheMean() {
        let a = task("a", total: nil, done: 0, status: .requestingMetadata)
        let b = task("b", total: nil, done: 5, status: .queued)
        XCTAssertEqual(aggregate([a, b]).fraction, 0)
    }

    func testCountsSizesAndSpeedAddUp() {
        let tasks = [
            task("a", total: 1_000, done: 100, status: .downloading, down: 50),
            task("b", total: 2_000, done: 0, status: .downloading, down: 25),
            task("c", total: nil, done: 300, status: .failed(.httpStatus(404))),
            task("d", total: 500, done: 500, status: .completed),
            task("e", total: 100, done: 0, status: .paused),
        ]
        let summary = aggregate(tasks)
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.totalBytes, 3_900)
        XCTAssertEqual(summary.activeCount, 2)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.speed.down, 75)
        XCTAssertEqual(summary.preview.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(summary.title, "5 downloads selected")
        XCTAssertEqual(summary.subtitle, "\(Int64(3_900).byteString) · 2 active · 1 failed · 1 done")
    }

    func testBulkCommandsFollowTheContextMenuRules() {
        let running = aggregate([task("a", total: 1, done: 0, status: .downloading),
                                 task("b", total: 1, done: 1, status: .completed)])
        XCTAssertTrue(running.canPause)
        XCTAssertFalse(running.canResume)
        XCTAssertFalse(running.canRetry)
        XCTAssertFalse(running.canMove, "nothing stopped and unfinished to move")

        let stopped = aggregate([task("a", total: 1, done: 0, status: .paused),
                                 task("b", total: 1, done: 0, status: .failed(.timedOut))])
        XCTAssertTrue(stopped.canResume)
        XCTAssertTrue(stopped.canRetry)
        XCTAssertTrue(stopped.canMove)
        XCTAssertFalse(stopped.canPause)
    }

    func testSubtitleLeavesOutZeroCounts() {
        let summary = aggregate([task("a", total: 10, done: 0, status: .paused),
                                 task("b", total: 20, done: 0, status: .queued)])
        XCTAssertEqual(summary.subtitle, Int64(30).byteString)
    }

    func testStatusLineNamesCountAndSize() {
        XCTAssertEqual(SelectionAggregate.statusLine(count: 1, totalBytes: 0), "1 selected")
        XCTAssertEqual(SelectionAggregate.statusLine(count: 3, totalBytes: 2048),
                       "3 selected · \(Int64(2048).byteString)")
    }
}
