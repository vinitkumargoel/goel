import XCTest
import AppKit
import GoelCore
@testable import GoelApp

final class SpeedRingTests: XCTestCase {
    func testKeepsTheNewestInOrder() {
        var ring = SpeedRing<Int>(capacity: 3)
        for n in 1...5 { ring.append(n) }
        XCTAssertEqual(ring.elements, [3, 4, 5])
        XCTAssertEqual(ring.count, 3)
    }

    func testSeedsFromTheTailOfAnArray() {
        XCTAssertEqual(SpeedRing(capacity: 2, elements: [1, 2, 3]).elements, [2, 3])
    }
}

@MainActor
final class TelemetryStoreTests: XCTestCase {

    private func task(_ id: UUID, down: Double, status: DownloadStatus = .downloading) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e.test/\(id)")!), name: "f",
                     saveDirectory: "/tmp", downloadSpeed: down, status: status)
    }

    func testSpeedsAndHistoryFollowTheQueue() {
        let store = TelemetryStore()
        let a = UUID(), b = UUID()
        store.sample(tasks: [task(a, down: 10), task(b, down: 20)],
                     combined: SpeedSample(down: 30, up: 0), recordHistory: true)
        XCTAssertEqual(store.displayedCombinedSpeed.down, 30)
        XCTAssertEqual(store.taskHistory(a).map(\.down), [10])
        // b leaves the queue: its read-out and ring go with it.
        store.sample(tasks: [task(a, down: 11)], combined: SpeedSample(down: 11, up: 0), recordHistory: true)
        XCTAssertNil(store.displayedTaskSpeed[b])
        XCTAssertEqual(store.taskHistory(b), [])
        XCTAssertEqual(store.taskHistory(a).map(\.down), [10, 11])
    }

    /// The status bar graphs the combined read-out (SFTP included), five minutes deep.
    func testGlobalHistoryKeepsFiveMinutesOfTheCombinedSpeed() {
        let store = TelemetryStore()
        let a = UUID()
        for n in 0..<(TelemetryStore.globalHistoryCap + 20) {
            store.sample(tasks: [task(a, down: 1)],
                         combined: SpeedSample(down: Double(n), up: 2), recordHistory: true)
        }
        XCTAssertEqual(TelemetryStore.globalHistoryCap, 300)
        XCTAssertEqual(store.globalHistory.count, 300)
        XCTAssertEqual(store.globalHistory.last?.down, Double(TelemetryStore.globalHistoryCap + 19))
        XCTAssertEqual(store.recentGlobalHistory(60).count, 60)
        XCTAssertEqual(store.recentGlobalHistory(60).first?.down, Double(TelemetryStore.globalHistoryCap - 40))
    }

    func testHistoryWindowTakesTheNewestPointsAndReportsPeaks() {
        let samples = (0..<90).map { SpeedSample(down: Double($0), up: Double(90 - $0)) }
        let tail = SpeedHistoryWindow.tail(samples, count: 60)
        XCTAssertEqual(tail.count, 60)
        XCTAssertEqual(tail.first?.down, 30)
        XCTAssertEqual(SpeedHistoryWindow.peakDown(tail), 89)
        XCTAssertEqual(SpeedHistoryWindow.peakUp(tail), 60)
        XCTAssertEqual(SpeedHistoryWindow.tail(samples, count: 0), [])
        XCTAssertEqual(SpeedHistoryWindow.average([2, 4]), 3)
        XCTAssertEqual(SpeedHistoryWindow.average([]), 0)
    }

    func testAnUnchangedTickPublishesNothing() {
        let store = TelemetryStore()
        let a = UUID()
        store.sample(tasks: [task(a, down: 5)], combined: SpeedSample(down: 5, up: 0), recordHistory: false)
        var fired = 0
        let sink = store.objectWillChange.sink { fired += 1 }
        store.sample(tasks: [task(a, down: 5)], combined: SpeedSample(down: 5, up: 0), recordHistory: false)
        XCTAssertEqual(fired, 0)
        sink.cancel()
    }

    func testPersistsOnlyUnfinishedRows() {
        let store = TelemetryStore()
        let live = UUID(), done = UUID()
        store.sample(tasks: [task(live, down: 1), task(done, down: 1)],
                     combined: .zero, recordHistory: true)
        let out = store.persistableHistory(for: [task(live, down: 0, status: .paused),
                                                 task(done, down: 0, status: .completed)])
        XCTAssertEqual(Set(out.keys), [live.uuidString])
    }
}

@MainActor
final class SFTPTransferStoreTests: XCTestCase {

    private func transfer(state: SFTPTransfer.State = .running) -> SFTPTransfer {
        var t = SFTPTransfer(connectionID: UUID(), name: "f", direction: .download,
                             isDirectory: false, localURL: URL(fileURLWithPath: "/tmp/f"),
                             remotePath: "/f")
        t.state = state
        return t
    }

    func testProgressIsAnnouncedOnTheSamplerTickNotPerCallback() {
        let store = SFTPTransferStore()
        store.transfers = [transfer()]
        var fired = 0
        let sink = store.objectWillChange.sink { fired += 1 }
        for n in 1...10 { store.transfers[0].bytes = Int64(n) }
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(store.transfers[0].bytes, 10, "the value itself is current at once")
        store.flushProgress()
        store.flushProgress()
        XCTAssertEqual(fired, 1)
        sink.cancel()
    }

    func testRowsAppearingOrChangingStateAreAnnouncedAtOnce() {
        let store = SFTPTransferStore()
        var fired = 0
        let sink = store.objectWillChange.sink { fired += 1 }
        store.transfers = [transfer()]
        store.transfers[0].state = .paused
        store.transfers = []
        XCTAssertEqual(fired, 3)
        sink.cancel()
    }
}

final class ClipboardMonitorFilterTests: XCTestCase {
    @MainActor
    func testPasswordManagerMarkersAreSkipped() {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType"] {
            XCTAssertTrue(ClipboardMonitor.isPrivate(types: [.string, NSPasteboard.PasteboardType(marker)]), marker)
        }
        XCTAssertFalse(ClipboardMonitor.isPrivate(types: [.string, .URL]))
        XCTAssertFalse(ClipboardMonitor.isPrivate(types: nil))
    }
}

final class NotificationContentTests: XCTestCase {
    func testCompletedBannersCarryTheTaskAndReplaceEachOther() {
        let id = UUID()
        let content = NotificationService.completedContent(taskID: id, name: "a.zip", sound: false)
        XCTAssertEqual(content.categoryIdentifier, "download.completed")
        XCTAssertEqual(content.threadIdentifier, "downloads")
        XCTAssertEqual(content.userInfo["taskID"] as? String, id.uuidString)
        XCTAssertEqual(NotificationService.identifier(for: id), "task-\(id.uuidString)")
    }

    func testResponsesMapToActions() {
        let id = UUID()
        let info: [AnyHashable: Any] = ["taskID": id.uuidString]
        XCTAssertEqual(NotificationService.response(actionIdentifier: "download.reveal", userInfo: info), .reveal(id))
        XCTAssertEqual(NotificationService.response(actionIdentifier: "download.open", userInfo: info), .open(id))
        XCTAssertNil(NotificationService.response(actionIdentifier: "download.open", userInfo: [:]))
    }

    func testCategoryOffersShowInFinderAndOpen() {
        let category = NotificationService.completedCategoryDefinition
        XCTAssertEqual(category.actions.map(\.identifier), ["download.reveal", "download.open"])
    }
}

final class LocalFileSizeTests: XCTestCase {
    func testAbsentIsZeroButUnreadableIsNil() throws {
        let missing = URL(fileURLWithPath: "/tmp/goel-\(UUID().uuidString)")
        XCTAssertEqual(AppViewModel.fileSize(missing), 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goel-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("part")
        try Data(count: 7).write(to: file)
        XCTAssertEqual(AppViewModel.fileSize(file), 7)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        // EACCES is not "nothing downloaded yet": resuming from 0 would truncate the partial.
        XCTAssertNil(AppViewModel.fileSize(file))
        XCTAssertThrowsError(try AppViewModel.localSizeForResume(file))
    }
}
