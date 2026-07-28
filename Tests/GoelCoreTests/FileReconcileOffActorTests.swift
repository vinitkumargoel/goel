import XCTest
@testable import GoelCore

final class FileReconcileOffActorTests: XCTestCase {

    private var tempDirs: [String] = []

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-reconcile-offactor-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        tempDirs.removeAll()
    }

    private func completedTask(name: String, saveDirectory: String) -> DownloadTask {
        DownloadTask(
            source: DownloadSource.parse("https://example.com/\(name)")!,
            name: name,
            saveDirectory: saveDirectory,
            totalBytes: 1,
            bytesDownloaded: 1,
            status: .completed,
            completedAt: Date())
    }

    private func makeManager(store: PersistenceStore) -> DownloadManager {
        DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: store)
    }

    func testAsyncSweepReachesTheSameVerdictsAsTheStartupPrune() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()

        let presentPath = (dir as NSString).appendingPathComponent("present.bin")
        FileManager.default.createFile(atPath: presentPath, contents: Data("x".utf8))
        let present = completedTask(name: "present.bin", saveDirectory: dir)

        let gonePath = (dir as NSString).appendingPathComponent("gone.bin")
        FileManager.default.createFile(atPath: gonePath, contents: Data("x".utf8))
        let gone = completedTask(name: "gone.bin", saveDirectory: dir)

        let unmounted = completedTask(name: "file.bin", saveDirectory: dir + "/unmounted")

        var paused = completedTask(name: "partial.bin", saveDirectory: dir)
        paused.status = .paused

        for t in [present, gone, unmounted, paused] { try store.saveTask(t) }

        let manager = makeManager(store: store)
        await manager.restore()
        let atLaunch = await manager.task(gone.id)
        XCTAssertNotNil(atLaunch, "precondition: nothing pruned at launch")

        try FileManager.default.removeItem(atPath: gonePath)
        await manager.reconcileCompletedFiles()

        let survivors = [present.id: "present", unmounted.id: "unmounted", paused.id: "paused"]
        for (id, label) in survivors {
            let task = await manager.task(id)
            XCTAssertNotNil(task, "\(label) must survive the async sweep")
        }
        let pruned = await manager.task(gone.id)
        XCTAssertNil(pruned, "the deleted payload's row is dropped")

        // Drain the serial persistence pipeline first, or this assertion races its detached writer.
        await manager.shutdown()
        XCTAssertFalse(try store.loadAllTasks().contains { $0.id == gone.id },
                       "the prune is written through to disk, not just the in-memory list")
    }

    func testSweepWithNothingMissingLeavesTheQueueIntact() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()

        let path = (dir as NSString).appendingPathComponent("kept.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let kept = completedTask(name: "kept.bin", saveDirectory: dir)

        var queued = completedTask(name: "queued.bin", saveDirectory: dir)
        queued.status = .queued

        for t in [kept, queued] { try store.saveTask(t) }

        let manager = makeManager(store: store)
        await manager.restore()
        await manager.reconcileCompletedFiles()

        let keptRow = await manager.task(kept.id)
        let queuedRow = await manager.task(queued.id)
        XCTAssertNotNil(keptRow)
        XCTAssertNotNil(queuedRow)
        // Stop the periodic sweep `restore()` started, so it does not outlive the test.
        await manager.shutdown()
    }

    func testRepeatedSweepsAreIdempotent() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()

        let gonePath = (dir as NSString).appendingPathComponent("gone.bin")
        FileManager.default.createFile(atPath: gonePath, contents: Data("x".utf8))
        let gone = completedTask(name: "gone.bin", saveDirectory: dir)
        try store.saveTask(gone)

        let manager = makeManager(store: store)
        await manager.restore()
        try FileManager.default.removeItem(atPath: gonePath)

        await manager.reconcileCompletedFiles()
        await manager.reconcileCompletedFiles()
        await manager.reconcileCompletedFiles()

        let survivingRow = await manager.task(gone.id)
        XCTAssertNil(survivingRow)
        // Drain the persistence pipeline before reading the store.
        await manager.shutdown()
        XCTAssertTrue(try store.loadAllTasks().isEmpty,
                      "three sweeps leave exactly one delete behind, not a resurrected row")
    }
}
