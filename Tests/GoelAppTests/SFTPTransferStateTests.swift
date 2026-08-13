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
        t.resetProgress()
        XCTAssertEqual(t.bytes, 0)
        XCTAssertEqual(t.speed, 0)
        XCTAssertNil(t.sampledSpeed)
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

    func testConflictPolicyOffersResumeBetweenOverwriteAndRename() {
        let policies = SFTPUploadConflictRequest.Policy.allCases
        XCTAssertEqual(policies, [.overwrite, .resume, .rename, .skip],
                       "the conflict sheet iterates allCases; order is the UI")
        XCTAssertEqual(SFTPUploadConflictRequest.Policy.resume.rawValue, "Resume")
    }
}
