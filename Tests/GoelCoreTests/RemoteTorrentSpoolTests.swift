import XCTest
@testable import GoelCore

/// A portal upload's spooled .torrent must live exactly as long as something can still use it: the row, an
/// Undo that can bring the row back, or a history entry's Download Again.
final class RemoteTorrentSpoolTests: XCTestCase {

    private var spool: URL!
    private var saveDir: String!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goel-spool-\(UUID().uuidString)")
        spool = root.appendingPathComponent("RemoteTorrents", isDirectory: true)
        saveDir = root.appendingPathComponent("save").path
        try FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: spool.deletingLastPathComponent())
    }

    private func manager(store: PersistenceStore? = nil) async -> DownloadManager {
        let m = DownloadManager(httpEngine: RecordingEngine(kind: .http), torrentEngine: RecordingEngine(kind: .torrent),
                                store: store, scanner: FakeScanner(), credentials: FakeCredentialStore())
        await m.setSpoolDirectory(spool)
        return m
    }

    private func spooledTask(_ m: DownloadManager) async throws -> (DownloadTask, URL) {
        let file = try RemoteTorrentSpool.write(Data("de".utf8), into: spool)
        let task = await m.add(source: .torrentFile(file), saveDirectory: saveDir, startPaused: true)
        return (task, file)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testAnUndoableRemovalKeepsTheSpoolFileSoUndoCanReAddIt() async throws {
        let m = await manager()
        let (task, file) = try await spooledTask(m)
        var hold: RemovalHold? = RemovalHold(manager: m)

        await m.removeAndReport(task.id, deleteData: false, hold: hold)
        XCTAssertTrue(exists(file), "Undo restores the row with this very source")
        await m.reinsert([task])
        let restored = await m.task(task.id)
        XCTAssertNotNil(restored)

        hold = nil
        await m.releaseRemovalHold(UUID()) // an unknown token is a no-op
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(exists(file), "the restored row still needs it")
    }

    func testTheSpoolFileGoesWhenTheUndoRecordIsDropped() async throws {
        let m = await manager()
        let (task, file) = try await spooledTask(m)
        var hold: RemovalHold? = RemovalHold(manager: m)
        await m.removeAndReport(task.id, deleteData: false, hold: hold)
        XCTAssertTrue(exists(file))

        hold = nil
        let deadline = Date().addingTimeInterval(5)
        while exists(file), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(exists(file), "a final removal must not leak the upload")
    }

    func testARemovalWithoutUndoDiscardsAtOnce() async throws {
        let m = await manager()
        let (task, file) = try await spooledTask(m)
        await m.removeAndReport(task.id, deleteData: false)
        XCTAssertFalse(exists(file))
    }

    func testAHistoryEntryKeepsTheFileUntilTheEntryIsRemoved() async throws {
        let store = try PersistenceStore()
        let m = await manager(store: store)
        let (task, file) = try await spooledTask(m)
        let entry = HistoryEntry(task: task)
        try store.saveHistoryEntry(entry)

        await m.removeAndReport(task.id, deleteData: false)
        XCTAssertTrue(exists(file), "Download Again re-adds from this file")

        await m.removeHistoryEntry(entry.id)
        XCTAssertFalse(exists(file))
    }

    func testClearingHistoryDiscardsFilesNoRowUses() async throws {
        let store = try PersistenceStore()
        let m = await manager(store: store)
        let (gone, goneFile) = try await spooledTask(m)
        let (listed, listedFile) = try await spooledTask(m)
        try store.saveHistoryEntry(HistoryEntry(task: gone))
        try store.saveHistoryEntry(HistoryEntry(task: listed))
        await m.removeAndReport(gone.id, deleteData: false)
        XCTAssertTrue(exists(goneFile))

        await m.clearHistory()
        XCTAssertFalse(exists(goneFile))
        XCTAssertTrue(exists(listedFile), "still a listed row's source")
    }

    func testLaunchSweepWaitsForTheQueueAndDeletesOnlyOldUnreferencedFiles() async throws {
        let m = await manager(store: try PersistenceStore())
        let orphan = try RemoteTorrentSpool.write(Data("de".utf8), into: spool)
        let fresh = try RemoteTorrentSpool.write(Data("de".utf8), into: spool)
        let old = Date().addingTimeInterval(-2 * DownloadManager.spoolSweepGrace)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: orphan.path)
        let foreign = spool.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: foreign.path)

        await m.sweepOrphanedSpool()
        XCTAssertTrue(exists(orphan), "before restore nothing is known to be unreferenced")

        await m.restore()
        let (_, listedFile) = try await spooledTask(m)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: listedFile.path)
        await m.sweepOrphanedSpool()
        XCTAssertFalse(exists(orphan))
        XCTAssertTrue(exists(listedFile))
        XCTAssertTrue(exists(fresh), "an upload may not have added its row yet")
        XCTAssertTrue(exists(foreign))
    }
}
