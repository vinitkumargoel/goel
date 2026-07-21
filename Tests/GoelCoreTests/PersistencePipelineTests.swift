import XCTest
@testable import GoelCore

/// Serial order + drain guarantees for ``PersistencePipeline``.
final class PersistencePipelineTests: XCTestCase {

    private var tempPaths: [String] = []

    private func tempDBPath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-pipe-\(UUID().uuidString).sqlite")
        tempPaths.append(url.path)
        return url.path
    }

    override func tearDownWithError() throws {
        for path in tempPaths {
            for suffix in ["", "-wal", "-shm"] {
                let p = path + suffix
                if FileManager.default.fileExists(atPath: p) {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }
        }
        tempPaths.removeAll()
    }

    func testEnqueueOrderPreservedThroughShutdown() async throws {
        let path = tempDBPath()
        let store = try PersistenceStore(path: path)
        let pipeline = PersistencePipeline(store: store)

        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = DownloadTask(
            id: id,
            source: .url(URL(string: "https://example.test/a.bin")!),
            name: "a.bin",
            saveDirectory: "/tmp/dl",
            status: .downloading,
            addedAt: base
        )
        var second = first
        second.status = .completed
        second.completedAt = base.addingTimeInterval(10)

        // Stale "still downloading" then authoritative completed — completed must win.
        pipeline.enqueue(.saveTask(first))
        pipeline.enqueue(.saveTask(second))
        await pipeline.shutdown()

        let loaded = try store.loadAllTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, id)
        XCTAssertEqual(loaded[0].status, .completed,
                       "later completed write must win over earlier downloading snapshot")
    }

    func testShutdownDrainsBeforeReturning() async throws {
        let path = tempDBPath()
        let store = try PersistenceStore(path: path)
        let pipeline = PersistencePipeline(store: store)

        let task = DownloadTask(
            source: .url(URL(string: "https://example.test/b.bin")!),
            name: "b.bin",
            saveDirectory: "/tmp/dl",
            status: .queued
        )
        pipeline.enqueue(.saveTask(task))
        pipeline.enqueue(.saveSettings(AppSettings()))
        await pipeline.shutdown()

        let loaded = try store.loadAllTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNotNil(try store.loadSettings())
    }

    func testErrorHandlerInstallIsSetOnce() async {
        let handler = PersistenceErrorHandler()
        let counter = Counter()
        handler.install { _ in await counter.incFirst() }
        handler.install { _ in await counter.incSecond() }
        await handler.report(NSError(domain: "t", code: 1))
        let (first, second) = await counter.snapshot()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
    }
}

/// Actor counter so install handlers stay Sendable.
private actor Counter {
    private var first = 0
    private var second = 0
    func incFirst() { first += 1 }
    func incSecond() { second += 1 }
    func snapshot() -> (Int, Int) { (first, second) }
}
