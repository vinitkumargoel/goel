import XCTest
@testable import GoelCore

final class FileReconcileTests: XCTestCase {

    private var tempDirs: [String] = []

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-reconcile-\(UUID().uuidString)").path
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
            completedAt: Date()
        )
    }

    func testPresentFileIsNotMissing() {
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("present.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let task = completedTask(name: "present.bin", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testDeletedFileWithLivingDirectoryIsMissing() {
        let dir = makeTempDir()
        let task = completedTask(name: "gone.bin", saveDirectory: dir)
        XCTAssertTrue(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testAbsentDirectoryIsAmbiguousAndKept() {
        // An unmounted volume takes the directory too; deleting on that would drop live downloads.
        let dir = makeTempDir() + "/unmounted-volume"
        let task = completedTask(name: "file.bin", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testMultiFileFolderPayloadCountsAsPresent() {
        // A multi-file torrent's payload is a folder at saveDirectory/name, not a file.
        let dir = makeTempDir()
        let folder = (dir as NSString).appendingPathComponent("Season 1")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let task = completedTask(name: "Season 1", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testRestorePrunesOnlyCompletedDownloadsWithDeletedFiles() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()

        let presentPath = (dir as NSString).appendingPathComponent("present.bin")
        FileManager.default.createFile(atPath: presentPath, contents: Data("x".utf8))
        let present = completedTask(name: "present.bin", saveDirectory: dir)

        let gone = completedTask(name: "gone.bin", saveDirectory: dir)

        let unmounted = completedTask(name: "file.bin", saveDirectory: dir + "/unmounted")

        var paused = completedTask(name: "partial.bin", saveDirectory: dir)
        paused.status = .paused

        for t in [present, gone, unmounted, paused] { try store.saveTask(t) }

        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: store)
        await manager.restore()

        let present2 = await manager.task(present.id)
        let gone2 = await manager.task(gone.id)
        let unmounted2 = await manager.task(unmounted.id)
        let paused2 = await manager.task(paused.id)

        XCTAssertNotNil(present2, "a completed download whose file is present is kept")
        XCTAssertNil(gone2, "a completed download whose file was deleted is pruned")
        XCTAssertNotNil(unmounted2, "an absent directory is ambiguous → kept")
        XCTAssertNotNil(paused2, "a non-completed download is never pruned")

        // Persistence writes on a detached task: read the store without draining and you race the writer.
        await manager.shutdown()
        XCTAssertFalse(try store.loadAllTasks().contains { $0.id == gone.id })
    }
}
