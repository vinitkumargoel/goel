import Foundation
import GoelCore

/// Owns every in-flight media conversion so one can be watched and stopped — previously no object
/// represented a running job at all. Caps concurrency, refuses duplicates, cleans up partials.
@MainActor
final class MediaJobCenter: ObservableObject {

    // MARK: - Job

    struct Job: Identifiable, Equatable {

        enum Kind: Equatable {
            case convert(ext: String)
            case extractAudio(format: AudioExtractionFormat)

            /// The file extension this job produces.
            var outputExtension: String {
                switch self {
                case .convert(let ext): return ext
                case .extractAudio(let format): return format.rawValue
                }
            }

            /// Present-tense verb phrase — "Converting to MKV".
            var activeTitle: String {
                switch self {
                case .convert(let ext): return "Converting to \(ext.uppercased())"
                case .extractAudio(let format): return "Extracting \(format.displayName)"
                }
            }

            /// Past-tense verb phrase — "Converted to MKV".
            var finishedTitle: String {
                switch self {
                case .convert(let ext): return "Converted to \(ext.uppercased())"
                case .extractAudio(let format): return "Extracted \(format.displayName)"
                }
            }
        }

        enum State: Equatable {
            case queued
            case running
            case cancelling
            case finished(URL, usedStreamCopy: Bool)
            case failed(String)
            case cancelled

            var isLive: Bool {
                switch self {
                case .queued, .running, .cancelling: return true
                case .finished, .failed, .cancelled: return false
                }
            }
        }

        let id = UUID()
        let input: URL
        let kind: Kind
        var state: State = .queued

        /// Source length. Nil means the bar must be indeterminate and the UI must
        /// say the length is unknown rather than invent a percentage.
        var totalSeconds: Double?
        var processedSeconds: Double = 0
        var speed: Double?
        var bytesWritten: Int64 = 0

        /// When `processedSeconds` last moved. Drives the stall flag.
        var lastAdvance = Date()
        var startedAt = Date()
        var finishedAt: Date?

        /// When the user pressed cancel, so a stop that is taking too long can say
        /// so instead of leaving a card that reads "Stopping…" forever.
        var cancelRequestedAt: Date?

        /// Whether cancelling this job actually deleted a half-written file. False when it was still
        /// queued — the card used to claim "Partial file removed" for the commonest cancel of all.
        var removedPartial = false

        /// Full ffmpeg output for the failure card's "Copy details".
        var log = ""

        /// The name of the file being worked on, for display.
        var sourceName: String { input.lastPathComponent }

        /// Completed fraction, or nil when the source length is unknown.
        var fraction: Double? {
            MediaEstimate.fraction(processed: processedSeconds, total: totalSeconds)
        }

        var eta: TimeInterval? {
            guard state == .running else { return nil }
            return MediaEstimate.eta(processed: processedSeconds,
                                     total: totalSeconds, speed: speed)
        }

        /// True when a running job has reported no forward progress for long
        /// enough to be worth flagging. Never kills anything on its own.
        func isStalled(now: Date = Date()) -> Bool {
            state == .running && MediaStall.isStalled(lastAdvance: lastAdvance, now: now)
        }

        /// True when a cancel has outlasted SIGTERM + SIGKILL. Past that the process is somewhere no
        /// signal reaches, and the card must offer a way out rather than sit on "Stopping…".
        func isStopStuck(now: Date = Date()) -> Bool {
            guard state == .cancelling, let cancelRequestedAt else { return false }
            return MediaStall.isStopStuck(requestedAt: cancelRequestedAt, now: now)
        }

        /// Two requests collide when they would produce the same thing from the same source — that is
        /// what makes a second click a duplicate rather than a second job.
        var dedupeKey: String { "\(input.path)→\(kind.outputExtension)" }
    }

    // MARK: - State

    @Published private(set) var jobs: [Job] = []

    /// How many conversions run at once. ffmpeg already saturates every core on one job, so a third
    /// concurrent transcode makes each slower without finishing the batch sooner.
    var concurrencyLimit: Int = 2 {
        didSet { pumpQueue() }
    }

    /// Whether anything is queued or running — feeds ``ActiveWorkGate`` so quitting
    /// mid-conversion raises the existing confirmation instead of orphaning ffmpeg.
    var hasLiveWork: Bool { jobs.contains { $0.state.isLive } }

    var liveCount: Int { jobs.filter { $0.state.isLive }.count }

    /// Completed fractions of running jobs that know their own length. Jobs with no declared
    /// duration are omitted rather than reported as zero — a missing number is not no progress.
    var runningFractions: [Double] {
        jobs.filter { $0.state == .running }.compactMap(\.fraction)
    }

    /// Where ffmpeg is (the user's Settings override). Kept in sync by the view model rather than
    /// read from settings here, so this type stays free of the settings cascade.
    var ffmpegOverride = ""

    /// Called when a job reaches a terminal state, so the view model can raise a
    /// notification without this type knowing about notifications.
    var onFinish: ((Job) -> Void)?

    /// Called whenever ``hasLiveWork`` may have flipped. A callback, because the active-work gate is
    /// driven by the download pump — a conversion with an empty queue would otherwise never reach it.
    var onLiveWorkChanged: (() -> Void)?

    /// Called once a second while anything is live, for surfaces that poll rather
    /// than observe (the Dock tile).
    var onTick: (() -> Void)?

    /// Cancellation handles, keyed by job. Separate from `Job` because that is an `Equatable` value
    /// type SwiftUI diffs, and a live process handle has no business inside it.
    private var cancellations: [UUID: FFmpegService.Cancellation] = [:]

    /// Drives the stall flag and the elapsed readout without every job needing its
    /// own timer. Runs only while something is live.
    private var ticker: Task<Void, Never>?

    // MARK: - Enqueue

    /// Why a request was refused, in the user's terms. Nil means it was accepted.
    enum Rejection: Equatable {
        case duplicate
        case unavailable(String)
        case notEnoughSpace(needed: Int64, available: Int64)

        var message: String {
            switch self {
            case .duplicate:
                return "That conversion is already running."
            case .unavailable(let reason):
                return reason
            case .notEnoughSpace(let needed, let available):
                return "Not enough disk space — this needs about \(needed.byteString) "
                     + "and there is \(available.byteString) free."
            }
        }
    }

    /// Queue a conversion; nil when accepted, else the reason it wasn't. Duplicate detection is why
    /// this returns anything — with no feedback, clicking Convert twice raced two ffmpegs.
    @discardableResult
    func enqueue(input: URL, kind: Job.Kind) -> Rejection? {
        if let reason = FFmpegService.unavailableReason(override: ffmpegOverride) {
            return .unavailable(reason)
        }
        let job = Job(input: input, kind: kind)
        guard !jobs.contains(where: { $0.state.isLive && $0.dedupeKey == job.dedupeKey }) else {
            return .duplicate
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            return .unavailable("The source file is missing.")
        }
        jobs.append(job)
        startTicker()
        pumpQueue()
        onLiveWorkChanged?()
        return nil
    }

    // MARK: - Cancel and dismiss

    /// Stop a running job, or drop a queued one. The partial output is deleted and
    /// the card says so — a silent deletion is worse than no deletion.
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            // Nothing ever launched, so nothing was written. Saying otherwise
            // would describe a deletion that did not happen.
            jobs[index].state = .cancelled
            jobs[index].removedPartial = false
            jobs[index].finishedAt = Date()
            scheduleAutoDismiss(id)
            pumpQueue()
            stopTickerIfIdle()
            onLiveWorkChanged?()
        case .running:
            jobs[index].state = .cancelling
            jobs[index].cancelRequestedAt = Date()
            cancellations[id]?.cancel()
            // The slot is free the moment the stop is requested, since a `.cancelling` job no longer counts
            // against the cap. Without this pump the next job would wait for the cancel's outcome.
            pumpQueue()
        case .cancelling, .finished, .failed, .cancelled:
            break
        }
    }

    /// Remove a finished / failed / cancelled card. Live jobs are never dropped
    /// this way — the ✕ on a live card cancels instead.
    func dismiss(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.state.isLive }
        stopTickerIfIdle()
    }

    /// Drop a card whose cancel is not completing, releasing its queue slot. Offered only once
    /// ``Job/isStopStuck(now:)``; honest that the process is condemned, we simply stop waiting on it.
    func forceDismiss(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .cancelling else { return }
        jobs.removeAll { $0.id == id }
        cancellations[id] = nil
        pumpQueue()
        stopTickerIfIdle()
        onLiveWorkChanged?()
    }

    /// Cancel everything. Used when the user confirms Quit with work in flight, so each ffmpeg is
    /// stopped properly and its partial removed rather than orphaned by the app's exit.
    func cancelAll() {
        for job in jobs where job.state.isLive { cancel(job.id) }
    }

    /// How long ``waitForShutdown()`` holds a quit open: enough for SIGTERM plus SIGKILL, short
    /// enough that a wedged ffmpeg can never stop the user quitting.
    static let shutdownGrace: TimeInterval = 4

    /// Wait for cancelled jobs to actually finish, so their partial files are
    /// removed before the app exits. Returns early once nothing is live.
    func waitForShutdown() async {
        let deadline = Date().addingTimeInterval(Self.shutdownGrace)
        while hasLiveWork, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The live job for a given source and target, if there is one — lets the
    /// context menu show "Converting to MKV — 38%" on the file it came from.
    func liveJob(input: URL, outputExtension: String) -> Job? {
        let key = "\(input.path)→\(outputExtension)"
        return jobs.first { $0.state.isLive && $0.dedupeKey == key }
    }

    /// Any live job for this source, whatever its target.
    func liveJobs(input: URL) -> [Job] {
        jobs.filter { $0.state.isLive && $0.input.path == input.path }
    }

    // MARK: - Queue pump

    /// Start as many queued jobs as the cap allows. `.cancelling` jobs are not counted: a cancel that
    /// never completes would hold its slot forever and, at cap 1, disable the feature entirely.
    private func pumpQueue() {
        var running = jobs.filter { $0.state == .running }.count
        for index in jobs.indices where jobs[index].state == .queued {
            guard running < max(1, concurrencyLimit) else { break }
            running += 1
            start(jobs[index].id)
        }
    }

    private func start(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .running
        jobs[index].startedAt = Date()
        jobs[index].lastAdvance = Date()
        let job = jobs[index]
        let cancellation = FFmpegService.Cancellation()
        cancellations[id] = cancellation
        let override = ffmpegOverride

        // Captured strongly on purpose: the task isn't stored here so there is no cycle, and a weak
        // capture would have to be re-read inside the `@Sendable` callback — which Swift 6 rejects.
        Task {
            // Probe first: the duration turns a spinner into a real percentage, and the codec decides whether
            // audio can be lifted without re-encoding. Shares `cancellation` so a cancel reaches the probe.
            let probe = await FFmpegService.probe(input: job.input, override: override,
                                                  cancellation: cancellation)
            // Checked before anything else: a job cancelled during the probe must report as cancelled, not
            // fall through into a pre-flight that would label it "not enough space".
            if cancellation.isCancelled {
                // No output name had been claimed yet, so there is nothing to say
                // was cleaned up.
                await MainActor.run {
                    self.finish(id: id, outcome: .cancelled, removedPartial: false)
                }
                return
            }
            await MainActor.run { self.applyProbe(id: id, probe: probe) }

            // Free-space pre-flight: extracting WAV from a two-hour video writes over a gigabyte, and
            // learning that from ffmpeg's ENOSPC after twenty minutes is the worst possible time.
            if case .extractAudio(let format) = job.kind,
               let needed = format.estimatedBytes(durationSeconds: probe.durationSeconds),
               let free = Self.availableSpace(near: job.input),
               free < Int64(Double(needed) * 1.2) {
                let message = Rejection.notEnoughSpace(needed: needed, available: free).message
                await MainActor.run {
                    self.finish(id: id, outcome: .failure(summary: message, detail: message))
                }
                return
            }

            let onProgress: @Sendable (MediaProgressSample) -> Void = { sample in
                Task { @MainActor in self.apply(sample, to: id) }
            }
            let outcome: FFmpegService.Outcome
            switch job.kind {
            case .convert(let ext):
                outcome = await FFmpegService.convert(input: job.input, toExtension: ext,
                                                      override: override,
                                                      cancellation: cancellation,
                                                      onProgress: onProgress)
            case .extractAudio(let format):
                outcome = await FFmpegService.extractAudio(input: job.input, format: format,
                                                           override: override,
                                                           sourceCodec: probe.audioCodec,
                                                           cancellation: cancellation,
                                                           onProgress: onProgress)
            }
            await MainActor.run { self.finish(id: id, outcome: outcome) }
        }
    }

    // MARK: - Updates

    private func applyProbe(id: UUID, probe: FFmpegService.Probe) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].totalSeconds = probe.durationSeconds
    }

    private func apply(_ sample: MediaProgressSample, to id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state.isLive else { return }
        if let seconds = sample.outTimeSeconds, seconds > jobs[index].processedSeconds {
            jobs[index].processedSeconds = seconds
            jobs[index].lastAdvance = Date()
        }
        if let size = sample.totalSize { jobs[index].bytesWritten = size }
        if let speed = sample.speed { jobs[index].speed = speed }
        // `progress=end` arrives while ffmpeg is still flushing and being reaped. Snapping the bar
        // here stops it resting at 97% through that gap and then vanishing.
        if sample.isFinal, let total = jobs[index].totalSeconds {
            jobs[index].processedSeconds = total
        }
    }

    /// `removedPartial` describes the cancelled case only: true when the run got
    /// far enough to claim an output file and therefore to delete one.
    private func finish(id: UUID, outcome: FFmpegService.Outcome,
                        removedPartial: Bool = true) {
        cancellations[id] = nil
        // Runs even when the job has already been force-dismissed, so its slot is
        // released and the ticker still stops.
        defer {
            pumpQueue()
            stopTickerIfIdle()
            onLiveWorkChanged?()
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finishedAt = Date()
        switch outcome {
        case .success(let url, let usedStreamCopy):
            jobs[index].state = .finished(url, usedStreamCopy: usedStreamCopy)
            // A finished job's bar must read 100%, which the last progress sample doesn't always
            // deliver (ffmpeg can exit before the final block is flushed through the pipe).
            if let total = jobs[index].totalSeconds {
                jobs[index].processedSeconds = total
            }
        case .failure(let summary, let detail):
            jobs[index].state = .failed(summary)
            // The card shows `summary`; `log` is what "Copy details" puts on the pasteboard, so it holds
            // ffmpeg's untruncated output. Storing the summary in both made the disclosure a duplicate.
            jobs[index].log = detail
        case .cancelled:
            jobs[index].state = .cancelled
            jobs[index].removedPartial = removedPartial
        }
        onFinish?(jobs[index])
        scheduleAutoDismiss(id)
    }

    // MARK: - Auto-dismiss

    /// How long a card that needs no reading stays up. Long enough to notice and click Reveal,
    /// short enough that twenty conversions don't stack. Failures are excluded — those get read.
    static let autoDismissDelay: TimeInterval = 12

    private func scheduleAutoDismiss(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .finished, .cancelled: break
        case .queued, .running, .cancelling, .failed: return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissDelay * 1_000_000_000))
            // `dismiss` is a no-op on a live job and on one already gone, so a card
            // the user revived or removed themselves is never touched.
            self?.dismiss(id)
        }
    }

    // MARK: - Ticker

    /// Re-publish once a second while anything is live, so the elapsed readout and
    /// the stall flag update without each card owning a timer.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard self.hasLiveWork else { return }
                // `objectWillChange` rather than mutating a field: nothing has changed except the clock, and
                // the derived values (elapsed, stalled) read `Date()` at render time.
                self.objectWillChange.send()
                self.onTick?()
            }
        }
    }

    private func stopTickerIfIdle() {
        guard !hasLiveWork else { return }
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Disk space

    /// Bytes available on the volume holding `url`'s directory.
    private static func availableSpace(near url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        return nil
    }
}
