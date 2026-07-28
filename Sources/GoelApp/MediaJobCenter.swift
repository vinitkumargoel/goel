import Foundation
import GoelCore

@MainActor
final class MediaJobCenter: ObservableObject {
    struct Job: Identifiable, Equatable {

        enum Kind: Equatable {
            case convert(ext: String)
            case extractAudio(format: AudioExtractionFormat)

            var outputExtension: String {
                switch self {
                case .convert(let ext): return ext
                case .extractAudio(let format): return format.rawValue
                }
            }

            var activeTitle: String {
                switch self {
                case .convert(let ext): return "Converting to \(ext.uppercased())"
                case .extractAudio(let format): return "Extracting \(format.displayName)"
                }
            }

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

        var totalSeconds: Double?
        var processedSeconds: Double = 0
        var speed: Double?
        var bytesWritten: Int64 = 0

        var lastAdvance = Date()
        var startedAt = Date()
        var finishedAt: Date?

        var cancelRequestedAt: Date?

        var removedPartial = false

        var log = ""

        var sourceName: String { input.lastPathComponent }

        var fraction: Double? {
            MediaEstimate.fraction(processed: processedSeconds, total: totalSeconds)
        }

        var eta: TimeInterval? {
            guard state == .running else { return nil }
            return MediaEstimate.eta(processed: processedSeconds,
                                     total: totalSeconds, speed: speed)
        }

        func isStalled(now: Date = Date()) -> Bool {
            state == .running && MediaStall.isStalled(lastAdvance: lastAdvance, now: now)
        }

        func isStopStuck(now: Date = Date()) -> Bool {
            guard state == .cancelling, let cancelRequestedAt else { return false }
            return MediaStall.isStopStuck(requestedAt: cancelRequestedAt, now: now)
        }

        var dedupeKey: String { "\(input.path)→\(kind.outputExtension)" }
    }

    @Published private(set) var jobs: [Job] = []

    /// 2 because one ffmpeg already saturates every core — more concurrent transcodes just slow each other.
    var concurrencyLimit: Int = 2 {
        didSet { pumpQueue() }
    }

    var hasLiveWork: Bool { jobs.contains { $0.state.isLive } }

    var liveCount: Int { jobs.filter { $0.state.isLive }.count }

    var runningFractions: [Double] {
        jobs.filter { $0.state == .running }.compactMap(\.fraction)
    }

    var ffmpegOverride = ""

    var onFinish: ((Job) -> Void)?

    var onLiveWorkChanged: (() -> Void)?

    var onTick: (() -> Void)?

    private var cancellations: [UUID: FFmpegService.Cancellation] = [:]

    private var ticker: Task<Void, Never>?

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

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
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
            // Without this pump the next job would wait on the cancel's outcome; a `.cancelling` job holds no slot.
            pumpQueue()
        case .cancelling, .finished, .failed, .cancelled:
            break
        }
    }

    func dismiss(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.state.isLive }
        stopTickerIfIdle()
    }

    func forceDismiss(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .cancelling else { return }
        jobs.removeAll { $0.id == id }
        cancellations[id] = nil
        pumpQueue()
        stopTickerIfIdle()
        onLiveWorkChanged?()
    }

    func cancelAll() {
        for job in jobs where job.state.isLive { cancel(job.id) }
    }

    /// 4s: long enough for SIGTERM plus SIGKILL, short enough that a wedged ffmpeg cannot block quitting.
    static let shutdownGrace: TimeInterval = 4

    func waitForShutdown() async {
        let deadline = Date().addingTimeInterval(Self.shutdownGrace)
        while hasLiveWork, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func liveJob(input: URL, outputExtension: String) -> Job? {
        let key = "\(input.path)→\(outputExtension)"
        return jobs.first { $0.state.isLive && $0.dedupeKey == key }
    }

    func liveJobs(input: URL) -> [Job] {
        jobs.filter { $0.state.isLive && $0.input.path == input.path }
    }

    /// `.cancelling` jobs are not counted: a cancel that never completes would hold its slot forever.
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

        // Captured strongly on purpose: a weak capture would be re-read inside the `@Sendable` callback, which Swift 6 rejects.
        Task {
            let probe = await FFmpegService.probe(input: job.input, override: override,
                                                  cancellation: cancellation)
            // Before anything else: a job cancelled during the probe must report cancelled, not "not enough space".
            if cancellation.isCancelled {
                await MainActor.run {
                    self.finish(id: id, outcome: .cancelled, removedPartial: false)
                }
                return
            }
            await MainActor.run { self.applyProbe(id: id, probe: probe) }

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
        if sample.isFinal, let total = jobs[index].totalSeconds {
            jobs[index].processedSeconds = total
        }
    }

    private func finish(id: UUID, outcome: FFmpegService.Outcome,
                        removedPartial: Bool = true) {
        cancellations[id] = nil
        // Deferred before the guard: a force-dismissed job must still release its slot and stop the ticker.
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
            if let total = jobs[index].totalSeconds {
                jobs[index].processedSeconds = total
            }
        case .failure(let summary, let detail):
            jobs[index].state = .failed(summary)
            jobs[index].log = detail
        case .cancelled:
            jobs[index].state = .cancelled
            jobs[index].removedPartial = removedPartial
        }
        onFinish?(jobs[index])
        scheduleAutoDismiss(id)
    }

    /// 12s: long enough to notice and click Reveal, short enough that twenty conversions do not stack.
    static let autoDismissDelay: TimeInterval = 12

    private func scheduleAutoDismiss(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .finished, .cancelled: break
        case .queued, .running, .cancelling, .failed: return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissDelay * 1_000_000_000))
            self?.dismiss(id)
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard self.hasLiveWork else { return }
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

    private static func availableSpace(near url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        return nil
    }
}
