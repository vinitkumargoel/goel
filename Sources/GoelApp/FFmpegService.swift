import Foundation
import GoelCore

enum FFmpegService {

    enum Source: String, Sendable {
        case override, bundled, system
    }

    enum Availability: Sendable {
        case found(URL, Source)
        case missing(String)
    }

    /// `$PATH` is deliberately not consulted: it would let any process pick the binary.
    private static let systemCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        NSHomeDirectory() + "/.local/bin/ffmpeg",
    ]

    private static var bundledPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("ffmpeg", isDirectory: false).path
    }

    static func resolve(override: String = "") -> Availability {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        // Settings-DB override: absolute non-interpreter only, else Convert is arbitrary code execution.
        if !trimmed.isEmpty {
            if ProcessSafety.isSafeExecutable(trimmed) {
                return .found(URL(fileURLWithPath: trimmed), .override)
            }
            // Must not fall through to the bundled copy: the user would never learn their path was ignored.
            return .missing(overrideRejectionMessage(for: trimmed))
        }

        if let bundledPath {
            if fm.isExecutableFile(atPath: bundledPath) {
                return .found(URL(fileURLWithPath: bundledPath), .bundled)
            }
            if fm.fileExists(atPath: bundledPath) {
                return .missing("""
                    Goel°’s built-in media converter is present but macOS won’t run it. \
                    This usually means the app was unpacked by a tool that dropped file \
                    permissions — drag Goel° to Applications from the original download, \
                    or re-download it.
                    """)
            }
        }

        if let system = systemCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return .found(URL(fileURLWithPath: system), .system)
        }
        return .missing("""
            Goel° couldn’t find ffmpeg, the tool it uses to convert video and pull out \
            audio. This copy of the app was built without the included one, and there \
            isn’t an ffmpeg installed on this Mac. Re-download Goel° from the official \
            release page to get the built-in copy, or install ffmpeg yourself and enter \
            its full path in Settings → Media tools → “ffmpeg path”.
            """)
    }

    static func executable(override: String = "") -> URL? {
        if case .found(let url, _) = resolve(override: override) { return url }
        return nil
    }

    static func isAvailable(override: String = "") -> Bool {
        if case .found = resolve(override: override) { return true }
        return false
    }

    static func unavailableReason(override: String = "") -> String? {
        if case .missing(let reason) = resolve(override: override) { return reason }
        return nil
    }

    private static func overrideRejectionMessage(for path: String) -> String {
        let fm = FileManager.default
        if !path.hasPrefix("/") {
            return "The ffmpeg path in Settings (“\(path)”) isn’t a full path. "
                 + "Enter the complete location, e.g. /opt/homebrew/bin/ffmpeg, or clear "
                 + "the field to use the copy included with Goel°."
        }
        if !fm.fileExists(atPath: path) {
            return "There’s no file at the ffmpeg path set in Settings (“\(path)”). "
                 + "Fix the path, or clear the field to use the copy included with Goel°."
        }
        if ProcessSafety.interpreterBlocklist.contains(path) {
            return "The ffmpeg path in Settings points at “\(path)”, which is a script "
                 + "interpreter rather than ffmpeg. Goel° won’t run it. Clear the field to "
                 + "use the copy included with Goel°."
        }
        return "The ffmpeg path in Settings (“\(path)”) isn’t a program Goel° can run. "
             + "Clear the field to use the copy included with Goel°."
    }

    /// Goes into the diagnostics bundle: never include user content beyond the typed path.
    static func resolutionSummary(override: String = "") -> String {
        switch resolve(override: override) {
        case .found(let url, .override): return "Using the ffmpeg you set in Settings: \(url.path)"
        case .found(let url, .bundled):  return "Using the ffmpeg included with Goel° (\(url.lastPathComponent))"
        case .found(let url, .system):   return "Using the ffmpeg installed on this Mac: \(url.path)"
        case .missing(let reason):       return reason
        }
    }

    enum Outcome: Sendable {
        case success(URL, usedStreamCopy: Bool)
        case failure(summary: String, detail: String)
        case cancelled
    }

    /// Created *before* launch and adopted after, so a cancel in the launch window is honoured.
    final class Cancellation: @unchecked Sendable {

        private let lock = NSLock()
        private var process: Process?
        private var launched = false
        private var cancelled = false

        init() {}

        static let graceSeconds: TimeInterval = 2

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        /// Returns false when a cancel already arrived — the caller must skip the launch.
        func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        /// Acts on a cancel that landed after `adopt` — the window `adopt` cannot cover.
        func markLaunched() {
            lock.lock()
            launched = true
            let needsStop = cancelled
            lock.unlock()
            if needsStop { terminateCurrent() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let canStop = launched
            lock.unlock()
            if canStop { terminateCurrent() }
        }

        /// Deliberately does not set `cancelled`, so a stuck probe doesn't fail the job.
        func terminateCurrent() {
            lock.lock()
            let target = process
            lock.unlock()
            guard let target, target.isRunning else { return }
            target.terminate()
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + Self.graceSeconds) {
                    // pid is 0 once reaped, and `kill(0, …)` signals Goel°'s own process group.
                    let pid = target.processIdentifier
                    guard target.isRunning, pid > 0 else { return }
                    kill(pid, SIGKILL)
                }
        }
    }

    struct Probe: Sendable {
        var durationSeconds: Double?
        var audioCodec: String?
    }

    /// `ffmpeg -i` exits non-zero by design — do not gate the parse on the exit status.
    static func probe(input: URL, override: String = "",
                      cancellation: Cancellation = Cancellation()) async -> Probe {
        guard case .found(let exe, _) = resolve(override: override) else { return Probe() }
        let process = Process()
        process.executableURL = exe
        process.environment = ProcessSafety.minimalEnvironment
        // No `-loglevel error`: Duration/Stream lines print at `info`, quietening kills the parse.
        process.arguments = ["-nostdin", "-hide_banner", "-i", input.path]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        guard cancellation.adopt(process) else { return Probe() }
        do {
            try process.run()
        } catch {
            return Probe()
        }
        cancellation.markLaunched()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(probeTimeout * 1_000_000_000))
            cancellation.terminateCurrent()
        }
        let data: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let read = readCapped(errPipe.fileHandleForReading, limit: probeOutputLimit)
                process.waitUntilExit()
                continuation.resume(returning: read)
            }
        }
        watchdog.cancel()
        let banner = String(data: data, encoding: .utf8) ?? ""
        return Probe(durationSeconds: MediaDuration.parse(banner: banner),
                     audioCodec: MediaDuration.audioCodec(banner: banner))
    }

    /// Runs before the user has a card to cancel from, so the wait must be finite.
    static let probeTimeout: TimeInterval = 30

    /// Caps banner memory: a malformed container makes a remote server drive an unbounded read.
    static let probeOutputLimit = 64 * 1024

    /// Keeps draining past `limit` so the writer never blocks on a full pipe and wedges.
    private static func readCapped(_ handle: FileHandle, limit: Int) -> Data {
        var collected = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count < limit {
                collected.append(chunk.prefix(limit - collected.count))
            }
        }
        return collected
    }

    static func convert(input: URL, toExtension ext: String, override: String = "",
                        cancellation: Cancellation = Cancellation(),
                        onProgress: @escaping @Sendable (MediaProgressSample) -> Void = { _ in })
        async -> Outcome {
        await run(input: input, outputExtension: ext,
                  copyArgs: ["-c", "copy"],
                  encodeArgs: [],
                  override: override,
                  cancellation: cancellation,
                  onProgress: onProgress)
    }

    /// `sourceCodec` must gate the copy: WAV will wrap an MP3 and hand back a fake .wav.
    static func extractAudio(input: URL, format: AudioExtractionFormat, override: String = "",
                             sourceCodec: String? = nil,
                             cancellation: Cancellation = Cancellation(),
                             onProgress: @escaping @Sendable (MediaProgressSample) -> Void = { _ in })
        async -> Outcome {
        await run(input: input, outputExtension: format.rawValue,
                  copyArgs: format.canCopy(sourceCodec: sourceCodec) ? AudioArguments.copy : nil,
                  encodeArgs: AudioArguments.encode(format),
                  override: override,
                  cancellation: cancellation,
                  onProgress: onProgress)
    }

    enum AudioArguments {

        static func encode(_ format: AudioExtractionFormat) -> [String] {
            switch format {
            case .mp3:  return ["-vn", "-acodec", "libmp3lame", "-q:a", "2"]
            case .m4a:  return ["-vn", "-acodec", "aac", "-b:a", "192k"]
            case .flac: return ["-vn", "-acodec", "flac"]
            case .wav:  return ["-vn", "-acodec", "pcm_s16le"]
            }
        }

        static let copy = ["-vn", "-acodec", "copy"]
    }

    /// Falls back to `encodeArgs` only on a codec mismatch, else a truncated source re-encodes for 20 min.
    private static func run(input: URL, outputExtension: String,
                            copyArgs: [String]?, encodeArgs: [String],
                            override: String,
                            cancellation: Cancellation,
                            onProgress: @escaping @Sendable (MediaProgressSample) -> Void)
        async -> Outcome {
        let exe: URL
        switch resolve(override: override) {
        case .found(let url, _): exe = url
        case .missing(let reason): return .failure(summary: reason, detail: reason)
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            let reason = "The source file is missing."
            return .failure(summary: reason, detail: reason)
        }
        // Must stay after every abort path: this creates a real (empty) file beside the user's media.
        let output = uniqueSibling(of: input, extension: outputExtension)

        if let copyArgs {
            let attempt = await launch(exe: exe, input: input, output: output,
                                       extraArgs: copyArgs,
                                       cancellation: cancellation, onProgress: onProgress)
            switch attempt {
            case .success:
                if let problem = outputProblem(at: output) {
                    discardPartial(at: output)
                    return .failure(summary: problem, detail: problem)
                }
                return .success(output, usedStreamCopy: true)
            case .cancelled:
                discardPartial(at: output)
                return .cancelled
            case .failure(let stderr, let launchError):
                if let launchError {
                    discardPartial(at: output)
                    return .failure(summary: launchError, detail: launchError)
                }
                guard MediaContainer.isCodecIncompatibility(stderr) else {
                    discardPartial(at: output)
                    return .failure(summary: message(from: stderr), detail: stderr)
                }
                // The partial is deliberately NOT deleted: it reserves the name against a concurrent job.
            }
        }

        let attempt = await launch(exe: exe, input: input, output: output,
                                   extraArgs: encodeArgs,
                                   cancellation: cancellation, onProgress: onProgress)
        switch attempt {
        case .success:
            if let problem = outputProblem(at: output) {
                discardPartial(at: output)
                return .failure(summary: problem, detail: problem)
            }
            return .success(output, usedStreamCopy: false)
        case .cancelled:
            discardPartial(at: output)
            return .cancelled
        case .failure(let stderr, let launchError):
            discardPartial(at: output)
            if let launchError { return .failure(summary: launchError, detail: launchError) }
            return .failure(summary: message(from: stderr), detail: stderr)
        }
    }

    /// ffmpeg can exit 0 having written nothing — a silent video leaves a zero-byte file.
    private static func outputProblem(at url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else {
            return "ffmpeg reported success but didn’t write a file."
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            return "ffmpeg produced an empty file — the source may have no track of that kind."
        }
        return nil
    }

    private enum Attempt {
        case success
        case cancelled
        case failure(stderr: String, launchError: String?)
    }

    private static func launch(exe: URL, input: URL, output: URL, extraArgs: [String],
                               cancellation: Cancellation,
                               onProgress: @escaping @Sendable (MediaProgressSample) -> Void)
        async -> Attempt {
        let process = Process()
        process.executableURL = exe
        // Don't hand ffmpeg the app's full environment (mirrors AntivirusScanner).
        process.environment = ProcessSafety.minimalEnvironment
        // `-nostdin` is load-bearing: without it an ffmpeg prompt hangs the job forever.
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-progress", "pipe:1", "-nostats",
                             "-i", input.path] + extraArgs + [output.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Stateful reader + readabilityHandler firing on an arbitrary queue: needs its own lock.
        let sink = ProgressSink(onProgress: onProgress)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: clear the handler or it spins on an empty pipe forever.
                handle.readabilityHandler = nil
                return
            }
            sink.feed(data)
        }

        guard cancellation.adopt(process) else {
            outPipe.fileHandleForReading.readabilityHandler = nil
            return .cancelled
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(stderr: "",
                            launchError: "Couldn’t launch ffmpeg: \(error.localizedDescription)")
        }
        cancellation.markLaunched()

        let errData: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Drain WHILE ffmpeg runs: waiting first deadlocks once it fills the pipe buffer.
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil

        if cancellation.isCancelled { return .cancelled }
        guard process.terminationStatus == 0 else {
            return .failure(stderr: String(data: errData, encoding: .utf8) ?? "",
                            launchError: nil)
        }
        return .success
    }

    private final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private var reader = MediaProgressReader()
        private let onProgress: @Sendable (MediaProgressSample) -> Void

        init(onProgress: @escaping @Sendable (MediaProgressSample) -> Void) {
            self.onProgress = onProgress
        }

        func feed(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            let samples = reader.consume(text)
            lock.unlock()
            // Deliver outside the lock: the callback hops to the main actor and would block pipe reads.
            for sample in samples { onProgress(sample) }
        }
    }

    private static func discardPartial(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Truncated from the *end* — ffmpeg puts the real error last.
    private static func message(from stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ffmpeg failed." }
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        return String(lastLine.suffix(200))
    }

    /// Claimed atomically with `O_EXCL` so two concurrent conversions can't both take the name.
    static func uniqueSibling(of input: URL, extension ext: String) -> URL {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let clamped = PathSafety.clampLength("\(stem).\(ext)")
        let base = (clamped as NSString).deletingPathExtension
        for attempt in 0...9_999 {
            let name = attempt == 0 ? "\(base).\(ext)" : "\(base) (\(attempt)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            // Not EEXIST means unwritable: hand the path back so ffmpeg gives the real diagnostic.
            if errno != EEXIST { return candidate }
        }
        // Never return `base.ext` here — it is known-occupied and `-y` would destroy it.
        let fallback = dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
        let fd = open(fallback.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 { close(fd) }
        return fallback
    }
}
