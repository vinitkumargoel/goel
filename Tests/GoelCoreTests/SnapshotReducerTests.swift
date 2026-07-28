import XCTest
@testable import GoelCore

final class SnapshotReducerTests: XCTestCase {

    private let aID = UUID()
    private let bID = UUID()

    private func task(_ id: UUID, _ name: String, _ status: DownloadStatus,
                      scan: String? = nil) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e/\(name)")!),
                     name: name, saveDirectory: "/tmp", status: status, scanVerdict: scan)
    }

    private func env(onAdded: Bool = false, onCompleted: Bool = true, onFailed: Bool = true,
                     onlyWhenInactive: Bool = false, isActive: Bool = false,
                     shutdown: String = "none") -> ReducerEnv {
        ReducerEnv(
            notify: NotifyPrefs(onAdded: onAdded, onCompleted: onCompleted,
                                onFailed: onFailed, onlyWhenInactive: onlyWhenInactive),
            isAppActive: isActive, autoShutdownAction: shutdown)
    }

    func testFirstSnapshotOnlySeedsNoNotifications() {
        let out = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)],
                                         env(onAdded: true))
        XCTAssertTrue(out.notifications.isEmpty)
        XCTAssertTrue(out.state.hasSeenFirstSnapshot)
        XCTAssertEqual(out.state.lastStatuses[aID], .downloading)
    }

    func testCompletionTransitionEmitsCompletedOnce() {
        let seeded = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)], env()).state
        let out = SnapshotReducer.reduce(seeded, [task(aID, "a", .completed)], env())
        XCTAssertEqual(out.notifications, [.completed("a")])
        let again = SnapshotReducer.reduce(out.state, [task(aID, "a", .completed)], env())
        XCTAssertTrue(again.notifications.isEmpty)
    }

    func testAddedAndFailedGatedByPrefs() {
        let seeded = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)], env()).state
        let added = SnapshotReducer.reduce(seeded, [task(aID, "a", .downloading),
                                                    task(bID, "b", .queued)], env(onAdded: true))
        XCTAssertEqual(added.notifications, [.added("b")])
        let failedOff = SnapshotReducer.reduce(seeded, [task(aID, "a", .failed(.timedOut))], env(onFailed: false))
        XCTAssertTrue(failedOff.notifications.isEmpty)
        let failedOn = SnapshotReducer.reduce(seeded, [task(aID, "a", .failed(.timedOut))], env(onFailed: true))
        XCTAssertEqual(failedOn.notifications, [.failed("a")])
    }

    func testOnlyWhenInactiveSuppressesWhileActive() {
        let seeded = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)], env()).state
        let out = SnapshotReducer.reduce(seeded, [task(aID, "a", .completed)],
                                         env(onlyWhenInactive: true, isActive: true))
        XCTAssertTrue(out.notifications.isEmpty)
        XCTAssertEqual(out.state.lastStatuses[aID], .completed)
    }

    func testScanFlaggedFiresOnceOnVerdictFlip() {
        let seeded = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .completed)], env()).state
        let flagged = SnapshotReducer.reduce(seeded, [task(aID, "a", .completed, scan: "flagged")], env())
        XCTAssertEqual(flagged.notifications, [.scanFlagged("a")])
        let again = SnapshotReducer.reduce(flagged.state, [task(aID, "a", .completed, scan: "flagged")], env())
        XCTAssertTrue(again.notifications.isEmpty)
    }

    func testDrainFiresExactlyOnceOnCompletionEdgeWithShutdown() {
        let active = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)],
                                            env(shutdown: "shutdown")).state
        let out = SnapshotReducer.reduce(active, [task(aID, "a", .completed)], env(shutdown: "shutdown"))
        XCTAssertEqual(out.drainIntent, .shutdown)
        let after = SnapshotReducer.reduce(out.state, [task(aID, "a", .completed)], env(shutdown: "shutdown"))
        XCTAssertNil(after.drainIntent)
    }

    func testDrainDoesNotFireOnPauseAll() {
        let active = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)],
                                            env(shutdown: "shutdown")).state
        let out = SnapshotReducer.reduce(active, [task(aID, "a", .paused)], env(shutdown: "shutdown"))
        XCTAssertNil(out.drainIntent)
    }

    func testDrainDoesNotFireWhileActiveWorkRemains() {
        let active = SnapshotReducer.reduce(
            ReducerState(), [task(aID, "a", .downloading), task(bID, "b", .downloading)],
            env(shutdown: "shutdown")).state
        let out = SnapshotReducer.reduce(active, [task(aID, "a", .completed), task(bID, "b", .downloading)],
                                         env(shutdown: "shutdown"))
        XCTAssertNil(out.drainIntent)
    }

    func testDrainInertWhenActionIsNone() {
        let active = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)], env()).state
        let out = SnapshotReducer.reduce(active, [task(aID, "a", .completed)], env(shutdown: "none"))
        XCTAssertNil(out.drainIntent)
    }

    func testDrainMapsEachAction() {
        for (action, intent): (String, DrainIntent) in [("quit", .quit), ("sleep", .sleep), ("shutdown", .shutdown)] {
            let active = SnapshotReducer.reduce(ReducerState(), [task(aID, "a", .downloading)],
                                                env(shutdown: action)).state
            let out = SnapshotReducer.reduce(active, [task(aID, "a", .completed)], env(shutdown: action))
            XCTAssertEqual(out.drainIntent, intent)
        }
    }
}

final class CSVEncoderTests: XCTestCase {

    func testPlainFieldIsUnquoted() {
        XCTAssertEqual(CSVEncoder.field("hello"), "hello")
    }

    func testQuotesWhenContainingSeparatorsOrQuotes() {
        XCTAssertEqual(CSVEncoder.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVEncoder.field("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(CSVEncoder.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testTableJoinsRowsAndQuotesCells() {
        let csv = CSVEncoder.table(header: ["name", "note"], [["a", "x,y"], ["b", "z"]])
        XCTAssertEqual(csv, "name,note\na,\"x,y\"\nb,z")
    }
}
