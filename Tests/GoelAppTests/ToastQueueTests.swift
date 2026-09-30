import XCTest
@testable import GoelApp

@MainActor
final class ToastQueueTests: XCTestCase {

    func testASecondToastWaitsInsteadOfOverwritingTheFirst() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("All 5 are already in your list")
        queue.show("Imported 5 links")
        XCTAssertEqual(queue.current?.message, "All 5 are already in your list")
        queue.advance()
        XCTAssertEqual(queue.current?.message, "Imported 5 links")
        queue.advance()
        XCTAssertNil(queue.current)
    }

    func testIdenticalMessagesAreNotQueuedTwice() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("Copied to clipboard")
        queue.show("Copied to clipboard")
        queue.show("Other")
        queue.show("Other")
        XCTAssertEqual(queue.pending.map(\.message), ["Other"])
    }

    func testABurstKeepsErrorsOverConfirmations() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("first")
        queue.show("boom", isError: true)
        for n in 0..<10 { queue.show("ok \(n)") }
        XCTAssertEqual(queue.pending.count, ToastQueue.maxPending)
        XCTAssertTrue(queue.pending.contains { $0.message == "boom" && $0.isError })
    }

    func testTheActionRunsOnceAndRetiresTheToast() {
        let queue = ToastQueue(autoAdvance: false)
        var runs = 0
        queue.show("Removed “a”", action: Toast.Action(title: "Undo") { runs += 1 })
        queue.show("next")
        queue.performAction()
        queue.performAction()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(queue.current?.message, "next")
    }

    func testDwellFavoursErrorsAndActions() {
        let plain = Toast(message: "a", isError: false, action: nil)
        let error = Toast(message: "a", isError: true, action: nil)
        let undo = Toast(message: "a", isError: false, action: Toast.Action(title: "Undo") {})
        XCTAssertLessThan(plain.dwell, error.dwell)
        XCTAssertGreaterThan(undo.dwell, error.dwell)
    }

    func testAnUndoShowsAtOnceInsteadOfQueueingBehindConfirmations() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("Added to queue")
        queue.show("Copied")
        queue.show("Removed “a”", action: Toast.Action(title: "Undo") {})
        XCTAssertEqual(queue.current?.message, "Removed “a”")
        XCTAssertFalse(queue.pending.contains { $0.message == "Added to queue" },
                       "the displaced confirmation is dropped, not replayed after the Undo")
    }

    func testADisplacedErrorWaitsAtTheFront() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("boom", isError: true)
        queue.show("Removed “a”", action: Toast.Action(title: "Undo") {})
        XCTAssertEqual(queue.current?.message, "Removed “a”")
        XCTAssertEqual(queue.pending.first?.message, "boom")
    }

    func testTrimmingNeverDropsAnUndoForInfoOrErrors() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("first")
        queue.show("Removed “a”", action: Toast.Action(title: "Undo") {})
        queue.show("Removed “b”", action: Toast.Action(title: "Undo") {})
        for n in 0..<6 { queue.show("err \(n)", isError: true) }
        XCTAssertEqual(queue.pending.count, ToastQueue.maxPending)
        XCTAssertTrue(queue.pending.contains { $0.message == "Removed “a”" })
    }

    func testDismissRetiresTheToastWhereverItIs() {
        let queue = ToastQueue(autoAdvance: false)
        let undo = queue.show("Removed “a”", action: Toast.Action(title: "Undo") {})
        queue.show("later")
        let waiting = queue.show("even later")
        queue.dismiss(try! XCTUnwrap(waiting))
        XCTAssertEqual(queue.pending.map(\.message), ["later"])
        queue.dismiss(try! XCTUnwrap(undo))
        XCTAssertEqual(queue.current?.message, "later")
    }

    func testEachToastIsAnnouncedOnceByTheQueue() {
        var spoken: [String] = []
        let queue = ToastQueue(autoAdvance: false, announce: { spoken.append($0) })
        queue.show("one")
        queue.show("two")
        queue.advance()
        XCTAssertEqual(spoken, ["one", "two"])
    }

    func testAutoAdvanceMovesOnByItself() async throws {
        let queue = ToastQueue(autoAdvance: true)
        queue.show("one")
        queue.show("two")
        // With a toast waiting, a plain confirmation yields after the busy dwell.
        try await Task.sleep(nanoseconds: UInt64((ToastQueue.busyDwell + 0.6) * 1_000_000_000))
        XCTAssertEqual(queue.current?.message, "two")
    }

    // MARK: Hover hold

    private func wait(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testErrorsStayAboutSixSeconds() {
        XCTAssertEqual(Toast(message: "a", isError: true, action: nil).dwell, 6, accuracy: 0.01)
        XCTAssertEqual(Toast(message: "a", isError: false, action: nil).dwell, 2.4, accuracy: 0.01)
    }

    /// `timeScale` 0.05 turns the 2.4 s dwell into 120 ms and the 2 s release grace into 100 ms.
    func testAHeldToastDoesNotExpire() async throws {
        let queue = ToastQueue(autoAdvance: true, announce: { _ in }, timeScale: 0.05)
        queue.show("one")
        queue.hold()
        try await wait(0.3)
        XCTAssertEqual(queue.current?.message, "one", "hovering pauses the countdown")
        queue.release()
        try await wait(0.3)
        XCTAssertNil(queue.current, "letting go restarts it")
    }

    func testReleaseGivesAtLeastAShortGrace() async throws {
        let queue = ToastQueue(autoAdvance: true, announce: { _ in }, timeScale: 0.05)
        queue.show("one")
        try await wait(0.1)
        queue.hold()
        try await wait(0.2)
        queue.release()
        // About 20 ms of dwell was left; the 100 ms grace outlasts it.
        try await wait(0.04)
        XCTAssertEqual(queue.current?.message, "one")
        try await wait(0.15)
        XCTAssertNil(queue.current)
    }

    func testAWaitingToastDoesNotCutAHeldOneShort() async throws {
        let queue = ToastQueue(autoAdvance: true, announce: { _ in }, timeScale: 0.05)
        queue.show("one")
        queue.hold()
        queue.show("two")
        try await wait(0.3)
        XCTAssertEqual(queue.current?.message, "one")
        queue.release()
        try await wait(0.17)
        XCTAssertEqual(queue.current?.message, "two")
    }

    func testReleaseWithoutHoldIsHarmless() {
        let queue = ToastQueue(autoAdvance: false)
        queue.show("one")
        queue.release()
        XCTAssertEqual(queue.current?.message, "one")
    }
}
