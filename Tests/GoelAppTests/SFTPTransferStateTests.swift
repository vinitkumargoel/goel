import XCTest
import GoelCore
@testable import GoelApp

/// The pause/resume state machine: rows are born `.waiting`, the first byte
/// flips them `.running`, and which controls appear hangs off these flags.
final class SFTPTransferStateTests: XCTestCase {

    private func transfer(direction: SFTPTransfer.Direction = .upload,
                          total: Int64 = 1000) -> SFTPTransfer {
        SFTPTransfer(connectionID: UUID(), name: "file.bin", direction: direction,
                     isDirectory: false, localURL: nil, remotePath: "dir/file.bin",
                     total: total)
    }

    func testBornWaitingAndFirstByteFlipsToRunning() {
        var t = transfer()
        XCTAssertEqual(t.state, .waiting)
        XCTAssertTrue(t.isActive, "waiting rows still occupy queue and destination")

        t.record(bytes: 0)
        XCTAssertEqual(t.state, .waiting, "zero bytes is not proof the transfer started")

        t.record(bytes: 1)
        XCTAssertEqual(t.state, .running)
    }

    func testPauseAndResumeAvailability() {
        var t = transfer()
        XCTAssertFalse(t.canPause, "waiting rows have no byte offset to resume from")

        t.record(bytes: 10)
        XCTAssertTrue(t.canPause)
        XCTAssertFalse(t.canResume)

        t.state = .paused
        XCTAssertFalse(t.canPause)
        XCTAssertTrue(t.canResume)
        XCTAssertTrue(t.isPaused)
        XCTAssertFalse(t.isActive)
    }

    func testRemoteCopyCannotPause() {
        var t = transfer(direction: .remoteCopy)
        t.record(bytes: 10)
        XCTAssertEqual(t.state, .running)
        XCTAssertFalse(t.canPause, "a remote copy restarts; it has no resumable offset")
    }

    func testOccupiesDestinationMatchesPartialOwnership() {
        var t = transfer()
        for (state, expected): (SFTPTransfer.State, Bool) in
            [(.waiting, true), (.running, true), (.paused, true),
             (.finished, false), (.cancelled, false), (.failed("x"), false)] {
            t.state = state
            XCTAssertEqual(t.occupiesDestination, expected, "\(state)")
        }
    }

    func testResetProgressClearsEverythingResumeRecomputes() {
        var t = transfer()
        t.record(bytes: 500)
        t.sampledSpeed = 123
        t.peakSpeed = 999
        t.endedAt = Date()
        t.noteResume(from: 400)
        t.resetProgress()
        XCTAssertEqual(t.bytes, 0)
        XCTAssertEqual(t.speed, 0)
        XCTAssertNil(t.sampledSpeed)
        // A retry is a fresh run: carrying any of these over dates the new attempt to
        // the failed one and averages its bytes across both.
        XCTAssertNil(t.startedAt)
        XCTAssertNil(t.endedAt)
        XCTAssertEqual(t.resumedFrom, 0)
        XCTAssertEqual(t.peakSpeed, 0)
    }

    func testDisplaySpeedPrefersSampledAndStallsDecayToZero() {
        var t = transfer()
        let start = Date()
        t.record(bytes: 500, now: start)
        t.record(bytes: 1000, now: start.addingTimeInterval(1))

        t.sampledSpeed = 42
        XCTAssertEqual(t.displaySpeed, 42, "the 500 ms sampler's value wins over live math")

        // 30 s of silence: the sliding window is empty and the live reading is zero.
        XCTAssertEqual(t.liveSpeed(at: start.addingTimeInterval(31)), 0,
                       "a stalled transfer must not freeze at its last speed")
    }

    func testEtaOnlyWhileActiveWithARate() {
        var t = transfer(total: 1000)
        t.record(bytes: 500)
        t.sampledSpeed = 100
        XCTAssertEqual(t.etaSeconds.map { Int($0.rounded()) }, 5)

        t.state = .paused
        XCTAssertNil(t.etaSeconds, "a paused row has no arrival estimate")

        t.state = .running
        t.sampledSpeed = 0
        XCTAssertNil(t.etaSeconds, "no rate, no estimate")
    }

    // MARK: - Inspector readings

    func testElapsedStartsAtTheFirstByteNotAdmission() {
        var t = transfer()
        let admitted = Date()
        XCTAssertNil(t.startedAt, "a row queued behind the connection cap has moved nothing")
        XCTAssertNil(t.elapsed(at: admitted.addingTimeInterval(30)))

        let firstByte = admitted.addingTimeInterval(30)
        t.record(bytes: 100, now: firstByte)
        XCTAssertEqual(t.startedAt, firstByte)
        XCTAssertEqual(t.elapsed(at: firstByte.addingTimeInterval(10))?.rounded(), 10,
                       "the 30 s spent queued is not transfer time")
    }

    func testElapsedFreezesOnceTheRowSettles() {
        var t = transfer()
        let start = Date()
        t.record(bytes: 1000, now: start)
        t.endedAt = start.addingTimeInterval(4)

        XCTAssertEqual(t.elapsed(at: start.addingTimeInterval(600))?.rounded(), 4,
                       "a finished transfer's duration must not keep climbing in the list")
    }

    func testAverageExcludesBytesTheFarEndAlreadyHeld() {
        var t = transfer(total: 1000)
        let start = Date()
        // A resumed run: 800 bytes were already on the server, 200 actually moved in 2 s.
        t.noteResume(from: 800)
        t.record(bytes: 800, now: start)
        t.record(bytes: 1000, now: start.addingTimeInterval(2))

        XCTAssertEqual(t.averageSpeed(at: start.addingTimeInterval(2)), 100,
                       "counting the resumed prefix would report a fake 500 B/s burst")
    }

    func testFolderAverageExcludesEverySkippedFile() {
        var t = transfer(total: 1000)
        let start = Date()
        // A resumed folder learns what it can skip one file at a time: three files worth
        // 300 B already on the server, then 100 B actually sent over 2 s.
        t.addResumed(100)
        t.addResumed(150)
        t.addResumed(50)
        XCTAssertEqual(t.resumedFrom, 300, "folder skips accumulate; they don't overwrite")

        t.record(bytes: 300, now: start)
        t.record(bytes: 400, now: start.addingTimeInterval(2))
        XCTAssertEqual(t.averageSpeed(at: start.addingTimeInterval(2)), 50,
                       "skipped files are recorded as progress, so they must also be "
                       + "recorded as skipped or the folder reports a fake burst")
    }

    func testAddResumedIgnoresNonPositiveSkips() {
        var t = transfer()
        t.addResumed(0)
        t.addResumed(-5)
        XCTAssertEqual(t.resumedFrom, 0, "a zero-length file is not resumed progress")
    }

    func testAverageWithdrawsRatherThanDivideByARoundingError() {
        var t = transfer()
        let start = Date()
        t.record(bytes: 1000, now: start)
        XCTAssertEqual(t.averageSpeed(at: start.addingTimeInterval(0.1)), 0,
                       "sub-second elapsed is reported as unknown, not as gigabytes per second")
    }

    func testRemainingBytesIsNilWithoutAKnownTotal() {
        var t = transfer(total: 0)
        t.record(bytes: 500)
        XCTAssertNil(t.remainingBytes, "a folder before its walk has no honest remainder")

        t.total = 1200
        XCTAssertEqual(t.remainingBytes, 700)

        t.record(bytes: 1200)
        XCTAssertNil(t.remainingBytes, "nothing left is not 'zero left' worth rendering")
    }

    func testStateLabelNamesTheDirectionWhileRunning() {
        var t = transfer(direction: .download)
        XCTAssertEqual(t.stateLabel, "Waiting")
        t.record(bytes: 10)
        XCTAssertEqual(t.stateLabel, "Downloading")
        t.state = .failed("Permission denied")
        XCTAssertEqual(t.stateLabel, "Failed")
        XCTAssertEqual(t.failureMessage, "Permission denied",
                       "the inspector shows the reason the pill can't fit")
    }

    func testFailureMessageIsNilForEveryNonFailedState() {
        var t = transfer()
        for state: SFTPTransfer.State in [.waiting, .running, .paused, .finished, .cancelled] {
            t.state = state
            XCTAssertNil(t.failureMessage, "\(state)")
        }
    }

    func testConflictPolicyOffersResumeBetweenOverwriteAndRename() {
        let policies = SFTPUploadConflictRequest.Policy.allCases
        XCTAssertEqual(policies, [.overwrite, .resume, .rename, .skip],
                       "the conflict sheet iterates allCases; order is the UI")
        XCTAssertEqual(SFTPUploadConflictRequest.Policy.resume.rawValue, "Resume")
    }
}
