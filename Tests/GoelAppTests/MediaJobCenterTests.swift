import XCTest
import GoelCore
@testable import GoelApp

@MainActor
final class MediaJobTests: XCTestCase {

    private func job(_ state: MediaJobCenter.Job.State = .running,
                     total: Double? = 100) -> MediaJobCenter.Job {
        var job = MediaJobCenter.Job(input: URL(fileURLWithPath: "/tmp/talk.mp4"),
                                     kind: .convert(ext: "mkv"))
        job.state = state
        job.totalSeconds = total
        return job
    }

    func testFractionIsNilWithoutADeclaredLength() {
        var j = job(total: nil)
        j.processedSeconds = 42
        XCTAssertNil(j.fraction, "an unknown length must stay unknown, not become 0% or 100%")
    }

    func testFractionNeverExceedsOne() {
        var j = job(total: 100)
        j.processedSeconds = 140
        XCTAssertEqual(j.fraction, 1)
    }

    func testEtaOnlyExistsWhileRunning() {
        for state in [MediaJobCenter.Job.State.queued, .cancelling, .cancelled] {
            var j = job(state, total: 100)
            j.processedSeconds = 10
            j.speed = 2
            XCTAssertNil(j.eta, "\(state) must not carry an ETA")
        }
        var running = job(.running, total: 100)
        running.processedSeconds = 10
        running.speed = 2
        XCTAssertNotNil(running.eta)
    }

    func testStallIsOnlyEverFlaggedOnARunningJob() {
        let longAgo = Date().addingTimeInterval(-MediaStall.threshold - 60)
        for state in [MediaJobCenter.Job.State.queued, .cancelling,
                      .cancelled, .failed("x")] {
            var j = job(state)
            j.lastAdvance = longAgo
            XCTAssertFalse(j.isStalled(), "\(state) is not 'not progressing' — it isn't progressing at all")
        }
        var running = job(.running)
        running.lastAdvance = longAgo
        XCTAssertTrue(running.isStalled())
    }

    func testStopIsNotStuckDuringTheNormalGrace() {
        var j = job(.cancelling)
        j.cancelRequestedAt = Date()
        XCTAssertFalse(j.isStopStuck())
        j.cancelRequestedAt = Date().addingTimeInterval(-MediaStall.stopGrace + 1)
        XCTAssertFalse(j.isStopStuck())
    }

    func testStopIsStuckOnceSigkillHasHadItsChance() {
        var j = job(.cancelling)
        j.cancelRequestedAt = Date().addingTimeInterval(-MediaStall.stopGrace - 1)
        XCTAssertTrue(j.isStopStuck())
    }

    func testOnlyACancellingJobCanBeStuckStopping() {
        for state in [MediaJobCenter.Job.State.running, .queued, .cancelled] {
            var j = job(state)
            j.cancelRequestedAt = Date().addingTimeInterval(-3600)
            XCTAssertFalse(j.isStopStuck(), "\(state) has no outstanding stop to be stuck")
        }
    }

    func testDedupeKeyIsSourceAndTarget() {
        let input = URL(fileURLWithPath: "/tmp/talk.mp4")
        let mkv = MediaJobCenter.Job(input: input, kind: .convert(ext: "mkv"))
        let mkvAgain = MediaJobCenter.Job(input: input, kind: .convert(ext: "mkv"))
        let mp3 = MediaJobCenter.Job(input: input, kind: .extractAudio(format: .mp3))
        let other = MediaJobCenter.Job(input: URL(fileURLWithPath: "/tmp/other.mp4"),
                                       kind: .convert(ext: "mkv"))
        XCTAssertEqual(mkv.dedupeKey, mkvAgain.dedupeKey)
        XCTAssertNotEqual(mkv.dedupeKey, mp3.dedupeKey)
        XCTAssertNotEqual(mkv.dedupeKey, other.dedupeKey)
    }

    func testLivenessCoversExactlyTheUnfinishedStates() {
        XCTAssertTrue(MediaJobCenter.Job.State.queued.isLive)
        XCTAssertTrue(MediaJobCenter.Job.State.running.isLive)
        XCTAssertTrue(MediaJobCenter.Job.State.cancelling.isLive)
        XCTAssertFalse(MediaJobCenter.Job.State.cancelled.isLive)
        XCTAssertFalse(MediaJobCenter.Job.State.failed("x").isLive)
        XCTAssertFalse(MediaJobCenter.Job.State
            .finished(URL(fileURLWithPath: "/tmp/a.mkv"), usedStreamCopy: true).isLive)
    }

    func testDurationTextSwitchesToMinutesPastSixty() {
        let start = Date()
        XCTAssertEqual(MediaJobCenter.Job.durationText(from: start,
                                                       to: start.addingTimeInterval(34)), "34s")
        XCTAssertEqual(MediaJobCenter.Job.durationText(from: start,
                                                       to: start.addingTimeInterval(372)), "6m 12s")
    }

    func testDurationTextNeverGoesNegative() {
        let start = Date()
        XCTAssertEqual(MediaJobCenter.Job.durationText(from: start,
                                                       to: start.addingTimeInterval(-30)), "0s")
    }

    func testRejectionMessagesNameTheActualNumbers() {
        let rejection = MediaJobCenter.Rejection.notEnoughSpace(needed: 1_500_000_000,
                                                               available: 200_000_000)
        XCTAssertEqual(rejection.message,
                       "Not enough disk space — this needs about \(Int64(1_500_000_000).byteString) "
                     + "and there is \(Int64(200_000_000).byteString) free.",
                       "the two sizes are the whole message — a bare “not enough space” "
                     + "leaves the user with nothing to act on")
        XCTAssertEqual(MediaJobCenter.Rejection.unavailable("no ffmpeg here").message,
                       "no ffmpeg here", "an unavailability reason is passed through verbatim")
    }
}

/// `enqueue` is main-actor and starts an unawaited `Task`, so only a test body that never suspends sees the queue before any process runs.
@MainActor
final class MediaJobCenterQueueTests: XCTestCase {

    private var directory: URL!
    private var center: MediaJobCenter!

    override func setUpWithError() throws {
        try XCTSkipIf(FFmpegService.unavailableReason() != nil,
                      "no ffmpeg on this machine")
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("media-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        center = MediaJobCenter()
    }

    override func tearDown() async throws {
        center?.cancelAll()
        center = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func source(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("not really media".utf8))
        return url
    }

    func testASecondIdenticalRequestIsRefused() {
        let input = source("talk.mp4")
        XCTAssertNil(center.enqueue(input: input, kind: .convert(ext: "mkv")))
        XCTAssertEqual(center.enqueue(input: input, kind: .convert(ext: "mkv")), .duplicate)
        XCTAssertEqual(center.jobs.count, 1)
    }

    func testADifferentTargetFromTheSameSourceIsNotADuplicate() {
        let input = source("talk.mp4")
        XCTAssertNil(center.enqueue(input: input, kind: .convert(ext: "mkv")))
        XCTAssertNil(center.enqueue(input: input, kind: .extractAudio(format: .mp3)))
        XCTAssertEqual(center.jobs.count, 2)
    }

    func testAMissingSourceIsRefusedRatherThanQueued() {
        let rejection = center.enqueue(input: directory.appendingPathComponent("gone.mp4"),
                                       kind: .convert(ext: "mkv"))
        XCTAssertEqual(rejection, .unavailable("The source file is missing."))
        XCTAssertTrue(center.jobs.isEmpty)
    }

    func testTheConcurrencyCapHoldsTheRestBack() {
        center.concurrencyLimit = 2
        for index in 0..<4 {
            center.enqueue(input: source("clip\(index).mp4"), kind: .convert(ext: "mkv"))
        }
        XCTAssertEqual(center.jobs.filter { $0.state == .running }.count, 2)
        XCTAssertEqual(center.jobs.filter { $0.state == .queued }.count, 2)
        XCTAssertEqual(center.liveCount, 4, "a queued job is still work in flight")
        XCTAssertTrue(center.hasLiveWork)
    }

    func testRaisingTheCapStartsWaitingJobs() {
        center.concurrencyLimit = 1
        for index in 0..<3 {
            center.enqueue(input: source("clip\(index).mp4"), kind: .convert(ext: "mkv"))
        }
        XCTAssertEqual(center.jobs.filter { $0.state == .running }.count, 1)
        center.concurrencyLimit = 3
        XCTAssertEqual(center.jobs.filter { $0.state == .running }.count, 3)
    }

    func testCancellingAQueuedJobReportsThatNothingWasWritten() throws {
        center.concurrencyLimit = 1
        center.enqueue(input: source("first.mp4"), kind: .convert(ext: "mkv"))
        center.enqueue(input: source("second.mp4"), kind: .convert(ext: "mkv"))
        let queued = try XCTUnwrap(center.jobs.first { $0.state == .queued })

        center.cancel(queued.id)
        let after = try XCTUnwrap(center.jobs.first { $0.id == queued.id })
        XCTAssertEqual(after.state, .cancelled)
        XCTAssertFalse(after.removedPartial)
        XCTAssertNotNil(after.finishedAt)
    }

    func testCancellingARunningJobGoesThroughCancellingAndRecordsWhen() throws {
        center.enqueue(input: source("talk.mp4"), kind: .convert(ext: "mkv"))
        let running = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(running.state, .running)

        center.cancel(running.id)
        let after = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(after.state, .cancelling)
        XCTAssertNotNil(after.cancelRequestedAt, "without this the card can never say a stop is stuck")
    }

    func testDismissRefusesToDropALiveJob() throws {
        center.enqueue(input: source("talk.mp4"), kind: .convert(ext: "mkv"))
        let job = try XCTUnwrap(center.jobs.first)
        center.dismiss(job.id)
        XCTAssertEqual(center.jobs.count, 1)
    }

    func testForceDismissOnlyAppliesToAStopInProgress() throws {
        center.enqueue(input: source("talk.mp4"), kind: .convert(ext: "mkv"))
        let job = try XCTUnwrap(center.jobs.first)

        center.forceDismiss(job.id)
        XCTAssertEqual(center.jobs.count, 1, "a running job is cancelled, never abandoned")

        center.cancel(job.id)
        center.forceDismiss(job.id)
        XCTAssertTrue(center.jobs.isEmpty)
    }

    func testForceDismissReleasesTheSlot() throws {
        center.concurrencyLimit = 1
        center.enqueue(input: source("first.mp4"), kind: .convert(ext: "mkv"))
        center.enqueue(input: source("second.mp4"), kind: .convert(ext: "mkv"))
        let running = try XCTUnwrap(center.jobs.first { $0.state == .running })

        center.cancel(running.id)
        XCTAssertEqual(center.jobs.filter { $0.state == .running }.count, 1)
        center.forceDismiss(running.id)
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs.filter { $0.state == .running }.count, 1)
    }

    func testLiveJobLookupFindsTheOneMatchingTarget() throws {
        let input = source("talk.mp4")
        center.enqueue(input: input, kind: .convert(ext: "mkv"))
        center.enqueue(input: input, kind: .extractAudio(format: .mp3))

        XCTAssertNotNil(center.liveJob(input: input, outputExtension: "mkv"))
        XCTAssertNotNil(center.liveJob(input: input, outputExtension: "mp3"))
        XCTAssertNil(center.liveJob(input: input, outputExtension: "webm"))
        XCTAssertEqual(center.liveJobs(input: input).count, 2)
    }

    func testCancelAllStopsEveryLiveJob() {
        center.concurrencyLimit = 1
        for index in 0..<3 {
            center.enqueue(input: source("clip\(index).mp4"), kind: .convert(ext: "mkv"))
        }
        center.cancelAll()
        XCTAssertTrue(center.jobs.allSatisfy { $0.state == .cancelling || $0.state == .cancelled },
                      "quitting must not leave a job still queued to start")
    }
}
