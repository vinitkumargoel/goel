import XCTest
import GoelCore
@testable import GoelApp

final class MenuBarQueueTests: XCTestCase {

    private func task(_ status: DownloadStatus) -> DownloadTask {
        let id = UUID()
        return DownloadTask(id: id, source: .url(URL(string: "https://e.test/\(id).bin")!), name: "\(id).bin",
                            saveDirectory: "/tmp", totalBytes: 10, status: status)
    }

    /// Twelve running used to read "Downloads · 8" with the other four simply gone.
    func testCountsEveryRowButListsOnlyTheCap() {
        let queue = MenuBarQueue(tasks: (0..<12).map { _ in task(.downloading) })
        XCTAssertEqual(queue.listed.count, 8)
        XCTAssertEqual(queue.total, 12)
        XCTAssertEqual(queue.hiddenCount, 4)
        XCTAssertEqual(queue.hiddenFilter, .active)
    }

    func testRunningRowsComeFirstAndFinishedOnesAreLeftOut() {
        let waiting = task(.queued)
        let running = task(.downloading)
        let queue = MenuBarQueue(tasks: [waiting, task(.completed), running])
        XCTAssertEqual(queue.listed.map(\.id), [running.id, waiting.id])
        XCTAssertEqual(queue.hiddenCount, 0)
    }

    func testHiddenWaitingRowsOpenTheWholeList() {
        let tasks = (0..<8).map { _ in task(.downloading) } + [task(.paused)]
        XCTAssertEqual(MenuBarQueue(tasks: tasks).hiddenFilter, .all)
    }
}
