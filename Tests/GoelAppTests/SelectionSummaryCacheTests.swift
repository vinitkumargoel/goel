import XCTest
import GoelCore
@testable import GoelApp

/// The multi-selection panel reads a memoised selection and summary instead of filtering every
/// row and refolding the aggregate in each body on each speed tick; the figures are unchanged.
final class SelectionSummaryCacheTests: XCTestCase {

    private func task(_ id: UUID, down: Double, total: Int64, done: Int64) -> DownloadTask {
        var task = DownloadTask(id: id, source: .url(URL(string: "https://e.test/\(id)")!), name: "f",
                                saveDirectory: "/tmp", downloadSpeed: down, status: .downloading)
        task.totalBytes = total
        task.bytesDownloaded = done
        return task
    }

    @MainActor
    func testSelectionSummaryIsReusedUntilTheRowsOrSpeedsChange() {
        let store = TelemetryStore()
        let a = UUID(), b = UUID()
        let tasks = [task(a, down: 10, total: 1_000, done: 250), task(b, down: 30, total: 3_000, done: 750)]
        let first = store.selectionSummary(for: tasks, revision: 1)
        let fresh = SelectionAggregate(tasks: tasks) { store.displaySpeed(for: $0) }
        XCTAssertEqual(first.aggregate.count, fresh.count)
        XCTAssertEqual(first.aggregate.totalBytes, fresh.totalBytes)
        XCTAssertEqual(first.aggregate.fraction, fresh.fraction)
        XCTAssertEqual(first.aggregate.speed, fresh.speed)
        XCTAssertEqual(first.queue, QueueOverview(tasks: tasks) { store.displaySpeed(for: $0) })
        XCTAssertEqual(store.selectionSummaryBuilds, 1)
        _ = store.selectionSummary(for: tasks, revision: 1)
        XCTAssertEqual(store.selectionSummaryBuilds, 1, "same rows and tick: reused")

        store.sample(tasks: [task(a, down: 50, total: 1_000, done: 250), task(b, down: 30, total: 3_000, done: 750)],
                     combined: SpeedSample(down: 80, up: 0), recordHistory: false)
        XCTAssertEqual(store.selectionSummary(for: tasks, revision: 1).aggregate.speed.down, 80)
        XCTAssertEqual(store.selectionSummaryBuilds, 2, "a new speed rebuilds it")

        XCTAssertEqual(store.selectionSummary(for: [tasks[0]], revision: 2).aggregate.count, 1)
        XCTAssertEqual(store.selectionSummaryBuilds, 3, "a new selection revision rebuilds it")
    }

    #if DEBUG
    @MainActor
    func testSelectedTasksAreFilteredOncePerSelectionOrListChange() {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        model.selectAll()
        let all = model.visibleTasks
        XCTAssertEqual(model.selectedTasks.map(\.id), all.map(\.id))
        let builds = model.selectedTasksBuilds
        _ = model.selectedTasks
        _ = model.selectionSummary
        XCTAssertEqual(model.selectedTasksBuilds, builds, "unchanged selection and list: reused")

        model.selectOnly(all[1].id)
        XCTAssertEqual(model.selectedTasks.map(\.id), [all[1].id])
        XCTAssertEqual(model.selectedTasksBuilds, builds + 1, "a new selection refilters")
        XCTAssertEqual(model.selectionSummary.aggregate.count, 1)

        model.toggleSelection(all[0].id)
        XCTAssertEqual(model.selectedTasks.map(\.id), [all[0].id, all[1].id], "list order, not click order")
        XCTAssertEqual(model.selectionSummary.aggregate.count, 2)
    }
    #endif
}
