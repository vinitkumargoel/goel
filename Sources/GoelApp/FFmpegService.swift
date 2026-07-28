import Foundation
import GoelCore

/// Hand-off to `ffmpeg` for post-download media work. Resolution order: the user's Settings
/// override, the bundled copy, then system locations — the override wins deliberately.
enum FFmpegService {

    /// Where the ffmpeg we are about to run came from. Carried in errors and the
    /// diagnostics text so "it works on my Mac" is an answerable question.
    enum Source: String, Sendable {
        case override, bundled, system
    }

    /// The outcome of looking for ffmpeg: a usable binary and its provenance, or
    /// a sentence that can be shown to a person as-is.
    enum Availability: Sendable {
        case found(URL, Source)
        case missing(String)
    }

    /// Candidate system install locations, in try order. `$PATH` is deliberately not consulted:
    /// the app inherits Finder's environment, and honouring it would let any process pick the binary.
    private static let systemCandidates = [
        "/opt/homebrew/bin/ffmpeg",     // Homebrew, Apple silicon
        "/usr/local/bin/ffmpeg",        // Homebrew, Intel (and hand-installs)
        "/opt/local/bin/ffmpeg",        // MacPorts
        NSHomeDirectory() + "/.local/bin/ffmpeg",
    ]

    /// The bundled binary's path, whether or not it exists.
    private static var bundledPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("ffmpeg", isDirectory: false).path
    }

    /// Full resolution, including the reason when it fails.
    static func resolve(override: String = "") -> Availability {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        // The override comes from the settings DB (same-user-writable). Accept only a concrete absolute
        // non-interpreter executable, or a "Convert" click becomes arbitrary code execution.
        if !trimmed.isEmpty {
            if ProcessSafety.isSafeExecutable(trimmed) {
                return .found(URL(fileURLWithPath: trimmed), .override)
            }
            // A bad override is the one case we must not quietly fall through on: the user typed a path,
            // believes it is in effect, and would otherwise never learn why nothing changed.
            return .missing(overrideRejectionMessage(for: trimmed))
        }

        if let bundledPath {
            if fm.isExecutableFile(atPath: bundledPath) {
                return .found(URL(fileURLWithPath: bundledPath), .bundled)
            }
            // Present but not runnable: the copy lost its execute bit (unzipped by a tool that drops
            // permissions) or was stripped. Distinct message — "install ffmpeg" is the wrong advice.
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

    /// Locate the ffmpeg binary, or nil when nothing usable was found. Thin
    /// wrapper over ``resolve(override:)`` for call sites that only need the path.
    static func executable(override: String = "") -> URL? {
        if case .found(let url, _) = resolve(override: override) { return url }
        return nil
    }

    static func isAvailable(override: String = "") -> Bool {
        if case .found = resolve(override: override) { return true }
        return false
    }

    /// The plain-language reason ffmpeg can't be used, or nil when it can. Show this instead of
    /// hiding Convert / Extract Audio: a silently absent item teaches the user the app can't do it.
    static func unavailableReason(override: String = "") -> String? {
        if case .missing(let reason) = resolve(override: override) { return reason }
        return nil
    }

    /// Why a configured override was refused, in the user's terms.
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

    /// One line describing where ffmpeg resolved from, for the Settings pane and the diagnostics
    /// bundle. Never contains user content beyond the path they typed themselves.
    static func resolutionSummary(override: String = "") -> String {
        switch resolve(override: override) {
        case .found(let url, .override): return "Using the ffmpeg you set in Settings: \(url.path)"
        case .found(let url, .bundled):  return "Using the ffmpeg included with Goel° (\(url.lastPathComponent))"
        case .found(let url, .system):   return "Using the ffmpeg installed on this Mac: \(url.path)"
        case .missing(let reason):       return reason
        }
    }

    /// A finished conversion. `.cancelled` is its own case, not a failure with a special message:
    /// the user asked for the stop, so it is neither an error nor a success.
    enum Outcome: Sendable {
        /// The produced file, and whether it was made by copying the streams
        /// verbatim (fast and lossless) rather than re-encoding.
        case success(URL, usedStreamCopy: Bool)
        /// A one-line summary for the card, plus ffmpeg's full output for "Copy details" — the summary
        /// must fit and read plainly, the detail is what gets pasted into a bug report.
        case failure(summary: String, detail: String)
        case cancelled
    }

    // MARK: - Cancellation

    /// A handle on one in-flight ffmpeg so something outside this file can stop it. Created *before*
    /// launch and adopted after, so a cancel arriving in the launch window is honoured.
    final class Cancellation: @unchecked Sendable {

        private let lock = NSLock()
        private var process: Process?
        private var launched = false
        private var cancelled = false

        init() {}

        /// How long a terminated ffmpeg gets to exit cleanly before it is killed.
        static let graceSeconds: TimeInterval = 2

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        /// Take ownership of a process built but not yet run. Returns false when a cancel already
        /// arrived, so the caller skips the launch instead of spawning something to kill at once.
        func adopt(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        /// Record that `run()` succeeded. If a cancel landed in between, act on it
        /// now — this is the window `adopt` cannot cover.
        func markLaunched() {
            lock.lock()
            launched = true
            let needsStop = cancelled
            lock.unlock()
            if needsStop { terminateCurrent() }
        }

        /// Request a stop. Safe to call at any point in the lifecycle, and safe to
        /// call more than once.
        func cancel() {
            lock.lock()
            cancelled = true
            let canStop = launched
            lock.unlock()
            if canStop { terminateCurrent() }
        }

        /// SIGTERM, then SIGKILL after a grace period — ffmpeg finalises on SIGTERM, but a wedged decoder
        /// never gets there. Deliberately does not set `cancelled`, so a stuck probe doesn't fail the job.
        func terminateCurrent() {
            lock.lock()
            let target = process
            lock.unlock()
            guard let target, target.isRunning else { return }
            target.terminate()
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + Self.graceSeconds) {
                    // `processIdentifier` reads back as 0 once reaped, and `kill(0, …)` signals the whole process
                    // group — i.e. Goel° itself. Never signal without a positive pid.
                    let pid = target.processIdentifier
                    guard target.isRunning, pid > 0 else { return }
                    kill(pid, SIGKILL)
                }
        }
    }

    // MARK: - Probing

    /// What a single `ffmpeg -i` pass can tell us about a source file before any
    /// work starts.
    struct Probe: Sendable {
        /// Source length in seconds, or nil for a stream with no declared length.
        /// Nil means the progress bar must be indeterminate — never faked.
        var durationSeconds: Double?
        /// The first audio stream's codec name (`aac`, `mp3`, `flac`, …), used to
        /// decide whether audio can be lifted out without re-encoding.
        var audioCodec: String?
    }

    /// Read duration and audio codec from ffmpeg's banner (`ffmpeg -i` exits non-zero by design).
    /// Takes the job's ``Cancellation`` so a probe on a stalled volume can't wedge the queue.
    static func probe(input: URL, override: String = "",
                      cancellation: Cancellation = Cancellation()) async -> Probe {
        guard case .found(let exe, _) = resolve(override: override) else { return Probe() }
        let process = Process()
        process.executableURL = exe
        process.environment = ProcessSafety.minimalEnvironment
        // No `-loglevel error` here: the Duration and Stream lines this parses are printed at
        // ffmpeg's default `info` level, so quietening it would silence the output being read.
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

    /// How long `ffmpeg -i` gets to describe a file before it is assumed wedged. Generous but
    /// finite — this runs before the user has any card to cancel from.
    static let probeTimeout: TimeInterval = 30

    /// Ceiling on the banner held in memory: a malformed container can make ffmpeg emit warnings
    /// per frame, so an unbounded read is driven by a remote server. The useful part is the first few hundred bytes.
    static let probeOutputLimit = 64 * 1024

    /// Read at most `limit` bytes, then keep draining and discarding so the writer never blocks on
    /// a full pipe — which would wedge the process we are waiting on rather than ending it.
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

    // MARK: - Conversions

    /// Convert `input` into a sibling file with extension `ext`; never overwrites the source. Tries a
    /// **stream copy first** — a container change is usually a bit-exact re-wrap, not a re-encode.
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

    /// Extract the audio track into a sibling file. `sourceCodec` gates the copy attempt because some
    /// muxers accept more than their name suggests — WAV will wrap an MP3 and hand back a fake .wav.
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

    // MARK: - Argument construction

    /// The ffmpeg flags each audio target is produced with. On this side of the module boundary
    /// because launching a process is app-layer; `GoelCore` also builds for the Linux daemon.
    enum AudioArguments {

        /// Arguments for a genuine re-encode into this format.
        static func encode(_ format: AudioExtractionFormat) -> [String] {
            switch format {
            case .mp3:  return ["-vn", "-acodec", "libmp3lame", "-q:a", "2"]
            case .m4a:  return ["-vn", "-acodec", "aac", "-b:a", "192k"]
            case .flac: return ["-vn", "-acodec", "flac"]
            case .wav:  return ["-vn", "-acodec", "pcm_s16le"]
            }
        }

        /// Arguments for lifting the existing audio track out untouched.
        static let copy = ["-vn", "-acodec", "copy"]
    }

    // MARK: - Process plumbing

    /// Run ffmpeg, preferring `copyArgs` and falling back to `encodeArgs` — but only when the failure
    /// reads as a container/codec mismatch, or a truncated source becomes a 20-minute re-encode.
    private static func run(input: URL, outputExtension: String,
                            copyArgs: [String]?, encodeArgs: [String],
                            override: String,
                            cancellation: Cancellation,
                            onProgress: @escaping @Sendable (MediaProgressSample) -> Void)
        async -> Outcome {
        // Surface the SAME explanation the UI uses for the disabled state, rather than a terse
        // "not found — brew install" that is wrong for a user who has no Homebrew.
        let exe: URL
        switch resolve(override: override) {
        case .found(let url, _): exe = url
        case .missing(let reason): return .failure(summary: reason, detail: reason)
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            let reason = "The source file is missing."
            return .failure(summary: reason, detail: reason)
        }
        // Claimed only once every reason to abort is ruled out: the claim creates a real (empty) file,
        // and leaving one beside the user's media because ffmpeg was missing would be its own bug.
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
                // A launch failure is about the binary, not the codecs — retrying
                // with different arguments would fail identically.
                if let launchError {
                    discardPartial(at: output)
                    return .failure(summary: launchError, detail: launchError)
                }
                guard MediaContainer.isCodecIncompatibility(stderr) else {
                    discardPartial(at: output)
                    return .failure(summary: message(from: stderr), detail: stderr)
                }
                // Fall through to the re-encode. The partial is deliberately NOT deleted: it reserves this
                // output name against a concurrent job, and ffmpeg's `-y` overwrites it on the retry anyway.
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

    /// Why an apparently-successful run produced no usable file, or nil when it did. ffmpeg can exit 0
    /// having written nothing — "extract audio" from a silent video leaves a zero-byte file.
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

    /// The result of one ffmpeg invocation.
    private enum Attempt {
        case success
        case cancelled
        /// ffmpeg's stderr, plus a launch-level message when the binary itself
        /// could not be started (in which case stderr is empty and meaningless).
        case failure(stderr: String, launchError: String?)
    }

    /// Launch ffmpeg once, streaming progress out of it while it runs.
    private static func launch(exe: URL, input: URL, output: URL, extraArgs: [String],
                               cancellation: Cancellation,
                               onProgress: @escaping @Sendable (MediaProgressSample) -> Void)
        async -> Attempt {
        let process = Process()
        process.executableURL = exe
        // Don't hand ffmpeg the app's full environment (mirrors AntivirusScanner).
        process.environment = ProcessSafety.minimalEnvironment
        // -y for explicitness, -nostdin so a prompt can't hang us, -loglevel error to keep stderr small.
        // -progress pipe:1 is the point: machine-readable progress that used to go to /dev/null.
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-progress", "pipe:1", "-nostats",
                             "-i", input.path] + extraArgs + [output.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // The reader is stateful (it stitches blocks across chunk boundaries) and readabilityHandler
        // fires on an arbitrary queue, so it gets its own lock rather than being touched from two places.
        let sink = ProgressSink(onProgress: onProgress)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF. Clear the handler or it spins on an empty pipe forever.
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
                // Drain stderr WHILE ffmpeg runs. Waiting first and reading after
                // deadlocks the moment ffmpeg writes more than a pipe buffer.
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

    /// Thread-safe wrapper around the stateful progress reader.
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
            // Deliver outside the lock: the callback hops to the main actor and
            // must never be able to block another pipe read.
            for sample in samples { onProgress(sample) }
        }
    }

    /// Delete a partial output. Called on every failure and every cancel so a
    /// half-written file never masquerades as a finished conversion.
    private static func discardPartial(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The last, most specific part of ffmpeg's complaint, or a plain fallback. Truncated from the
    /// *end* because ffmpeg puts the real error last; the caller keeps the full text.
    private static func message(from stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ffmpeg failed." }
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        return String(lastLine.suffix(200))
    }

    /// A never-clobber sibling path claimed atomically with `O_EXCL`, so two concurrent conversions
    /// targeting the same output name can't both find it free and have the second overwrite the first.
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
            // Anything other than "it already exists" means we cannot write here at all. Hand the path back
            // and let ffmpeg produce the real diagnostic — it says *why* far better than errno.
            if errno != EEXIST { return candidate }
        }
        // Ten thousand siblings all taken. Returning `base.ext` would hand back a name we know is
        // occupied and let `-y` destroy it, so fall through to one nothing can already hold.
        let fallback = dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
        let fd = open(fallback.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 { close(fd) }
        return fallback
    }
}
