import XCTest
@testable import GoelCore

/// Adding a source that dedups onto an existing task must honour what "add" promises —
/// the payload ends up on disk — not just hand back whatever row carries the same key.
final class DedupReAddTests: XCTestCase {

    private func makeManager(restoring task: DownloadTask) async throws -> DownloadManager {
        let store = try PersistenceStore()
        try store.upsert(task)
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: store)
        await manager.restore()
        return manager
    }

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "goel-dedup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testReAddingAFailedSourceRetriesIt() async throws {
        let source = DownloadSource.parse("https://example.com/build.tar.gz")!
        var task = DownloadTask(source: source, name: "build.tar.gz", saveDirectory: "/tmp")
        task.status = .failed(.httpStatus(404))
        let manager = try await makeManager(restoring: task)

        let returned = await manager.add(source: source)
        XCTAssertEqual(returned.id, task.id, "the failed row is retried, not duplicated")
        // The mock engine may pick the task up synchronously — queued or already running both mean "retrying".
        XCTAssertTrue(returned.status.isActiveWork, "expected active work, got \(returned.status)")
    }

    func testReAddingACompletedSourceWhoseFileIsGoneStartsAfresh() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = DownloadSource.parse("https://example.com/data.bin")!
        var task = DownloadTask(source: source, name: "data.bin", saveDirectory: dir)
        task.status = .completed
        // The payload exists at restore time, so the startup prune keeps the row …
        FileManager.default.createFile(atPath: task.savePath, contents: Data("x".utf8))
        let manager = try await makeManager(restoring: task)

        // … and is deleted just before the re-add — inside the reconcile sweep's
        // 5-second window, which is exactly the race a CLI caller can hit.
        try FileManager.default.removeItem(atPath: task.savePath)
        let returned = await manager.add(source: source)
        XCTAssertNotEqual(returned.id, task.id, "the dead row must not answer for the payload")
        XCTAssertTrue(returned.status.isActiveWork, "expected active work, got \(returned.status)")
        let snapshot = await manager.snapshot
        XCTAssertEqual(snapshot.count, 1, "the stale completed row was dropped, not kept alongside")
    }

    func testReAddingACompletedSourceWhoseFileExistsIsIdempotent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let source = DownloadSource.parse("https://example.com/kept.bin")!
        var task = DownloadTask(source: source, name: "kept.bin", saveDirectory: dir)
        task.status = .completed
        FileManager.default.createFile(atPath: task.savePath, contents: Data("x".utf8))
        let manager = try await makeManager(restoring: task)

        let returned = await manager.add(source: source)
        XCTAssertEqual(returned.id, task.id)
        XCTAssertEqual(returned.status, .completed)
    }
}
