import XCTest
import GoelCore
@testable import GoelApp

@MainActor
final class CommandStateTests: XCTestCase {

    private func task(_ status: DownloadStatus, id: UUID = UUID()) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e.test/\(id).bin")!), name: "\(id).bin",
                     saveDirectory: "/tmp", totalBytes: 10, status: status)
    }

    private func snap(_ tasks: [DownloadTask], selection: Set<UUID> = [], listVisible: Bool = true)
        -> CommandState.Snapshot {
        .make(tasks: tasks, visible: tasks, selection: selection, listVisible: listVisible,
              autoShutdown: .none)
    }

    func testAnEmptyQueueDisablesEverything() {
        let s = snap([])
        XCTAssertTrue(s.isEmpty)
        XCTAssertFalse(s.hasPausable)
        XCTAssertFalse(s.hasResumable)
        XCTAssertFalse(s.hasSelection)
    }

    func testPauseAllIsOnlyOfferedWhenSomethingRunsOrWaits() {
        XCTAssertFalse(snap([task(.completed), task(.paused)]).hasPausable)
        XCTAssertTrue(snap([task(.queued)]).hasPausable)
        XCTAssertTrue(snap([task(.downloading)]).hasPausable)
        XCTAssertTrue(snap([task(.paused)]).hasResumable)
    }

    func testSelectionCommandsFollowWhatIsSelected() {
        let running = task(.downloading), done = task(.completed)
        let s = snap([running, done], selection: [done.id])
        XCTAssertTrue(s.hasSelection)
        XCTAssertFalse(s.selectionCanPause)
        XCTAssertTrue(s.selectionHasData)
        XCTAssertTrue(snap([running, done], selection: [running.id]).selectionCanPause)
    }

    func testSelectionCommandsAreOffWhileTheSFTPBrowserIsShowing() {
        let done = task(.completed)
        XCTAssertFalse(snap([done], selection: [done.id], listVisible: false).hasSelection)
    }

    func testApplyPublishesOnlyOnARealChange() {
        let state = CommandState()
        var fired = 0
        let sink = state.objectWillChange.sink { fired += 1 }
        let running = snap([task(.downloading)])
        XCTAssertTrue(state.apply(running))
        XCTAssertFalse(state.apply(running))
        // A different task with the same booleans is no change for the menus.
        XCTAssertFalse(state.apply(snap([task(.downloading)])))
        XCTAssertEqual(fired, 1)
        sink.cancel()
    }
}
