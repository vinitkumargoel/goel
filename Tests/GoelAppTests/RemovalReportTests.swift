import XCTest
import Combine
import GoelCore
@testable import GoelApp

/// The removal toast is worded from what the manager did, and offers Undo only when no file was unlinked.
final class RemovalReportTests: XCTestCase {

    func testAListRemovalAlwaysOffersUndo() {
        let one = RemovalReport.make(names: ["a.zip"], outcomes: [.nothingToDelete], deleteData: false)
        XCTAssertEqual(one.message, "Removed “a.zip” from the list")
        XCTAssertTrue(one.offersUndo)
        XCTAssertFalse(one.filesStayInTrash)
        let many = RemovalReport.make(names: ["a", "b"], outcomes: [.nothingToDelete, .nothingToDelete],
                                      deleteData: false)
        XCTAssertEqual(many.message, "Removed 2 downloads from the list")
        XCTAssertTrue(many.offersUndo)
    }

    func testTrashedOffersUndoThatSaysTheFileStaysInTheTrash() {
        let report = RemovalReport.make(names: ["a.zip"], outcomes: [.trashed], deleteData: true)
        XCTAssertEqual(report.message, "Moved “a.zip” to the Trash")
        XCTAssertTrue(report.offersUndo)
        XCTAssertEqual(report.restoredMessage(names: ["a.zip"]),
                       "Restored “a.zip” to the list — its file is still in the Trash")
    }

    func testAnUnlinkedFileIsNeverUndoable() {
        let deleted = RemovalReport.make(names: ["a.part"], outcomes: [.deleted], deleteData: true)
        XCTAssertEqual(deleted.message, "Deleted “a.part”")
        XCTAssertFalse(deleted.offersUndo)
        let torrent = RemovalReport.make(names: ["t"], outcomes: [.handledByEngine], deleteData: true)
        XCTAssertEqual(torrent.message, "Removed “t”")
        XCTAssertFalse(torrent.offersUndo)
    }

    /// The manager already posted "…its file is still on disk"; a second toast would repeat it.
    func testAFileKeptOnDiskGetsNoToastOfItsOwn() {
        let report = RemovalReport.make(names: ["a"], outcomes: [.keptOnDisk(reason: "busy")], deleteData: true)
        XCTAssertNil(report.message)
        XCTAssertFalse(report.offersUndo)
    }

    func testAMixedBatchIsWordedAsAWholeWithoutUndo() {
        let report = RemovalReport.make(names: ["a", "b", "c"],
                                        outcomes: [.trashed, .deleted, .keptOnDisk(reason: "x")], deleteData: true)
        XCTAssertEqual(report.message, "Removed 2 downloads")
        XCTAssertFalse(report.offersUndo)
        let trashed = RemovalReport.make(names: ["a", "b"], outcomes: [.trashed, .nothingToDelete], deleteData: true)
        XCTAssertEqual(trashed.message, "Moved the files of 2 downloads to the Trash")
        XCTAssertTrue(trashed.offersUndo)
    }

    func testNothingRemovedSaysNothing() {
        XCTAssertNil(RemovalReport.make(names: [], outcomes: [], deleteData: true).message)
    }

    func testRestoringSomethingAlreadyBackSaysSo() {
        let report = RemovalReport.make(names: ["a"], outcomes: [.nothingToDelete], deleteData: false)
        XCTAssertEqual(report.restoredMessage(names: []), "Already in your list")
        XCTAssertEqual(report.restoredMessage(names: ["a"]), "Restored “a”")
        XCTAssertEqual(report.restoredMessage(names: ["a", "b"]), "Restored 2 downloads")
    }
}

@MainActor
final class NotificationDelegateTests: XCTestCase {

    /// A banner click that cold-launches the app lands before the queue is restored.
    func testResponsesWaitForTheHandler() {
        let delegate = NotificationDelegate()
        let id = UUID()
        delegate.deliver(.show(id))
        delegate.deliver(.reveal(id))
        XCTAssertEqual(delegate.buffered, [.show(id), .reveal(id)])
        var handled: [NotificationService.Response] = []
        delegate.setResponseHandler { handled.append($0) }
        XCTAssertEqual(handled, [.show(id), .reveal(id)])
        XCTAssertTrue(delegate.buffered.isEmpty)
        delegate.deliver(.open(id))
        XCTAssertEqual(handled.last, .open(id))
    }

    func testTheCountdownBannerCancelIsRecognised() {
        let cancel = NotificationService.response(actionIdentifier: "autoshutdown.cancel",
                                                  categoryIdentifier: NotificationService.autoShutdownCategory,
                                                  userInfo: [:])
        XCTAssertEqual(cancel, .cancelAutoShutdown)
    }

    func testBannersYieldToTheInWindowToastWhileTheWindowIsUp() {
        XCTAssertTrue(NotificationDelegate.shouldSuppress(isActive: true, onlyWhenInactive: false, showingMainWindow: true))
        XCTAssertFalse(NotificationDelegate.shouldSuppress(isActive: true, onlyWhenInactive: false, showingMainWindow: false),
                       "menu-bar-only: no toast to see, so the banner shows")
        XCTAssertTrue(NotificationDelegate.shouldSuppress(isActive: true, onlyWhenInactive: true, showingMainWindow: false))
        XCTAssertFalse(NotificationDelegate.shouldSuppress(isActive: false, onlyWhenInactive: true, showingMainWindow: true))
    }
}

@MainActor
final class AppAppearanceTests: XCTestCase {

    func testOnlyRealChangesPublish() {
        let appearance = AppAppearance()
        var publishes = 0
        let token = appearance.objectWillChange.sink { publishes += 1 }
        var settings = AppSettings()
        appearance.apply(settings)
        XCTAssertEqual(publishes, 0)
        settings.menuBarExtraEnabled.toggle()
        appearance.apply(settings)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(appearance.menuBarExtraEnabled, settings.menuBarExtraEnabled)
        token.cancel()
    }
}

final class AppServicesHelperTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("goel-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheDatabaseAndItsJournalsMoveTogetherOwnerOnly() throws {
        let base = dir.appendingPathComponent("queue.sqlite").path
        let aside = dir.appendingPathComponent("queue.broken.sqlite").path
        for suffix in ["", "-wal", "-shm"] { try Data("x".utf8).write(to: URL(fileURLWithPath: base + suffix)) }
        try AppViewModel.moveDatabaseFiles(from: base, to: aside)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(fm.fileExists(atPath: base + suffix), "a leftover \(suffix) would be replayed")
            XCTAssertEqual(try fm.attributesOfItem(atPath: aside + suffix)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testAFailedMoveIsRolledBack() throws {
        let base = dir.appendingPathComponent("queue.sqlite").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: base))
        try Data("x".utf8).write(to: URL(fileURLWithPath: base + "-wal"))
        let missingFolder = dir.appendingPathComponent("nope/queue.broken.sqlite").path
        XCTAssertThrowsError(try AppViewModel.moveDatabaseFiles(from: base, to: missingFolder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base + "-wal"))
    }

    func testFetchFailuresReadAsSentencesNotEnumDumps() {
        XCTAssertEqual(AppViewModel.fetchFailureMessage(NetworkGuard.FetchError.transport("timed out")), "timed out")
        let url = URLError(.cannotFindHost)
        XCTAssertEqual(AppViewModel.fetchFailureMessage(url), url.localizedDescription)
        XCTAssertFalse(AppViewModel.fetchFailureMessage(NetworkGuard.FetchError.httpStatus(404)).contains("httpStatus"))
    }

    func testSFTPDownloadsAreQuarantinedWithTheirServerAsOrigin() {
        var connection = SFTPConnection(name: "nas", host: "nas.local", port: 2222, username: "me")
        XCTAssertEqual(AppViewModel.sftpSourceURL(connection, remotePath: "/srv/a.dmg")?.absoluteString,
                       "sftp://nas.local:2222/srv/a.dmg")
        connection.port = 22
        XCTAssertEqual(AppViewModel.sftpSourceURL(connection, remotePath: "a.dmg")?.absoluteString,
                       "sftp://nas.local/a.dmg")
    }
}
