import XCTest
@testable import GoelCore

/// The filesystem-reconciliation rule (see `DownloadManager+FileReconcile`):
/// a completed download whose file the user deleted or moved is dropped from the
/// list, while ambiguous cases (unmounted volume / moved download folder) and
/// non-completed tasks are left untouched.
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

    // MARK: The pure decision

    func testPresentFileIsNotMissing() {
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("present.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let task = completedTask(name: "present.bin", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testDeletedFileWithLivingDirectoryIsMissing() {
        let dir = makeTempDir()   // directory exists, file never created
        let task = completedTask(name: "gone.bin", saveDirectory: dir)
        XCTAssertTrue(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testAbsentDirectoryIsAmbiguousAndKept() {
        // An unmounted volume / moved-away download folder: both the file and its
        // directory are gone. That's ambiguous, so it must NOT count as deleted.
        let dir = makeTempDir() + "/unmounted-volume"
        let task = completedTask(name: "file.bin", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    func testMultiFileFolderPayloadCountsAsPresent() {
        // A multi-file torrent's payload is a folder (saveDirectory/name).
        let dir = makeTempDir()
        let folder = (dir as NSString).appendingPathComponent("Season 1")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let task = completedTask(name: "Season 1", saveDirectory: dir)
        XCTAssertFalse(DownloadManager.completedPayloadIsMissing(task, fileManager: .default))
    }

    // MARK: End-to-end through restore()

    func testRestorePrunesOnlyCompletedDownloadsWithDeletedFiles() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()

        // present: file on disk → kept.
        let presentPath = (dir as NSString).appendingPathComponent("present.bin")
        FileManager.default.createFile(atPath: presentPath, contents: Data("x".utf8))
        let present = completedTask(name: "present.bin", saveDirectory: dir)

        // gone: directory exists, file deleted → pruned.
        let gone = completedTask(name: "gone.bin", saveDirectory: dir)

        // unmounted: directory itself absent → conservatively kept.
        let unmounted = completedTask(name: "file.bin", saveDirectory: dir + "/unmounted")

        // paused with a missing file → never pruned (only completed are checked).
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

        // The prune is also written through to disk, not just the in-memory list.
        XCTAssertFalse(try store.loadAllTasks().contains { $0.id == gone.id })
    }
}
