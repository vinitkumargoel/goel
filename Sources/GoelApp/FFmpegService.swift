import Foundation
import GoelCore

/// Hand-off to `ffmpeg` for post-download media work: remuxing/converting a
/// finished video and extracting its audio track.
///
/// A packaged build carries its OWN static ffmpeg inside `Contents/Resources`
/// (see `Scripts/fetch_ffmpeg.sh`), because "no Homebrew required" is the whole
/// promise of a self-contained .app — and for a long time it was not true here:
/// the build script shipped no copy and this type auto-detected `/opt/homebrew`,
/// so Convert and Extract Audio simply did not exist for anyone who had never
/// installed Homebrew. That is the failure this file is written to make loud.
///
/// Resolution order is: the user's explicit Settings override, then the bundled
/// copy, then the common system install locations. The override wins over the
/// bundled binary on purpose — a user who typed a path did so to use THAT build
/// (a newer one, or a GPL build with encoders the bundled LGPL one lacks).
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

    /// Candidate system install locations, in the order they are tried. `$PATH`
    /// is deliberately NOT consulted: the app runs with whatever environment
    /// Finder handed it, which is not the user's shell `PATH`, so searching it
    /// would be theatre — and honouring an inherited `PATH` would let any
    /// same-user process decide which binary a "Convert" click launches.
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
        // The override path comes from the settings DB (same-user-writable). Only
        // accept it if it's a concrete absolute non-interpreter executable — never
        // a relative $PATH name or a shell/script interpreter, which would turn a
        // "Convert"/"Extract Audio" click into arbitrary code execution. Mirrors
        // the guard AntivirusScanner already applies to its equivalent setting.
        if !trimmed.isEmpty {
            if ProcessSafety.isSafeExecutable(trimmed) {
                return .found(URL(fileURLWithPath: trimmed), .override)
            }
            // A bad override is the one case we must NOT quietly fall through on:
            // the user typed a path, believes it is in effect, and would otherwise
            // never learn why nothing changed.
            return .missing(overrideRejectionMessage(for: trimmed))
        }

        if let bundledPath {
            if fm.isExecutableFile(atPath: bundledPath) {
                return .found(URL(fileURLWithPath: bundledPath), .bundled)
            }
            // Present but not runnable: the copy survived into the bundle and then
            // lost its execute bit (unzipped by a tool that drops permissions) or
            // was stripped by an over-eager cleaner. Distinct message — "install
            // ffmpeg" is the wrong advice here.
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

    /// The plain-language reason ffmpeg can't be used, or nil when it can.
    ///
    /// The UI should show this instead of hiding Convert / Extract Audio: a menu
    /// item that silently isn't there teaches the user the app can't do the job,
    /// which is both wrong and unfixable from their side.
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

    /// One line describing where ffmpeg resolved from, for the Settings pane and
    /// the diagnostics bundle. Never contains user content beyond the path they
    /// themselves typed.
    static func resolutionSummary(override: String = "") -> String {
        switch resolve(override: override) {
        case .found(let url, .override): return "Using the ffmpeg you set in Settings: \(url.path)"
        case .found(let url, .bundled):  return "Using the ffmpeg included with Goel° (\(url.lastPathComponent))"
        case .found(let url, .system):   return "Using the ffmpeg installed on this Mac: \(url.path)"
        case .missing(let reason):       return reason
        }
    }

    /// A finished conversion.
    ///
    /// `.cancelled` is a distinct case rather than a failure with a special
    /// message: the user asked for the stop, so it is neither an error to report
    /// nor a success to celebrate, and the two get different treatment in the UI.
    enum Outcome: Sendable {
        /// The produced file, and whether it was made by copying the streams
        /// verbatim (fast and lossless) rather than re-encoding.
        case success(URL, usedStreamCopy: Bool)
        /// A one-line summary for the card, and ffmpeg's full output for the
        /// "Copy details" affordance.
        ///
        /// Two values rather than one because they answer different questions: the
        /// summary has to fit on a card and be readable by a person who does not
        /// know what a muxer is, while the detail is what gets pasted into a bug
        /// report. Collapsing them means the disclosure box shows the user the
        /// same truncated sentence they are already looking at.
        case failure(summary: String, detail: String)
        case cancelled
    }

    // MARK: - Cancellation

    /// A handle on one in-flight ffmpeg, so something outside this file can stop
    /// it. Previously nothing held the `Process` at all, which is the reason
    /// Convert and Extract Audio could not be cancelled.
    ///
    /// Created *before* the process launches and adopted after, so a cancel that
    /// arrives during the launch window is honoured rather than lost. Lock-guarded
    /// and `@unchecked Sendable`, matching ``ActiveWorkGate``'s house style.
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

        /// Take ownership of a process that has been built but not yet run.
        /// Returns false when a cancel already arrived, so the caller can skip the
        /// launch entirely instead of spawning something it must immediately kill.
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

        /// SIGTERM, then SIGKILL after a grace period. ffmpeg handles SIGTERM by
        /// finalising and exiting, which is worth waiting a moment for; a build
        /// wedged inside a decoder never gets there, hence the escalation.
        ///
        /// Deliberately does *not* set `cancelled`, so a watchdog can abandon one
        /// wedged step — the probe — without condemning the job that follows it.
        /// A file whose banner ffmpeg cannot produce in thirty seconds is still a
        /// file worth trying to convert, just without a determinate bar.
        func terminateCurrent() {
            lock.lock()
            let target = process
            lock.unlock()
            guard let target, target.isRunning else { return }
            target.terminate()
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + Self.graceSeconds) {
                    // `processIdentifier` reads back as 0 once the process has been
                    // reaped, and `kill(0, …)` signals the entire process group —
                    // i.e. Goel° itself. Never signal without a positive pid.
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

    /// Read duration and audio codec out of ffmpeg's own banner.
    ///
    /// `ffmpeg -i <file>` with no output prints its stream summary to stderr and
    /// then exits **non-zero** ("At least one output file must be specified") —
    /// that exit status is expected here and is not a failure.
    ///
    /// AVFoundation would answer the duration half of this faster and without a
    /// process, but it cannot open MKV or WebM at all, and it cannot answer the
    /// codec half without loading tracks. One uniform probe that works for every
    /// container the app can download beats a fast path that covers half of them.
    ///
    /// Takes the job's ``Cancellation`` so that a probe is stoppable too. It is a
    /// real process against a file that may live on a stalled network volume, and
    /// leaving it outside the cancellation chain means a cancel during this phase
    /// does nothing, the job wedges, and — with the concurrency cap counting it —
    /// the whole queue stops. ``probeTimeout`` is the backstop for a probe that
    /// hangs where no signal reaches it.
    static func probe(input: URL, override: String = "",
                      cancellation: Cancellation = Cancellation()) async -> Probe {
        guard case .found(let exe, _) = resolve(override: override) else { return Probe() }
        let process = Process()
        process.executableURL = exe
        process.environment = ProcessSafety.minimalEnvironment
        // No `-loglevel error` here: the Duration and Stream lines this reads are
        // printed at ffmpeg's default `info` level, so quietening it would silence
        // the very output being parsed.
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

    /// How long `ffmpeg -i` gets to describe a file before it is assumed wedged.
    /// Generous — a large file on a slow volume takes real time to scan — but
    /// finite, because this runs before the user has any card to cancel from.
    static let probeTimeout: TimeInterval = 30

    /// Ceiling on the banner we will hold in memory.
    ///
    /// The banner is a handful of lines for a well-formed file, but the file came
    /// off the internet: a malformed container can make ffmpeg emit warnings per
    /// frame, and `readDataToEndOfFile` on that is an unbounded allocation driven
    /// by a remote server. Everything worth parsing is in the first few hundred
    /// bytes.
    static let probeOutputLimit = 64 * 1024

    /// Read at most `limit` bytes, then keep draining and discarding so the writer
    /// never blocks on a full pipe (which would wedge the process we are waiting
    /// on rather than ending it).
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

    /// Convert `input` into a sibling file with extension `ext`. Never overwrites
    /// the source.
    ///
    /// Tries a **stream copy first**. A container change (MP4 → MKV and friends)
    /// can almost always be done by re-wrapping the existing streams, which takes
    /// seconds and is bit-exact. Passing no codec flags at all — what this used to
    /// do — makes ffmpeg pick encoders from the container defaults and re-encode
    /// the video, spending minutes of CPU *and* losing a generation of quality on
    /// a job that should have copied. The re-encode is kept as the fallback for
    /// the cases where the target muxer genuinely refuses the source codec.
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

    /// Extract the audio track of `input` into a sibling file of the chosen
    /// format.
    ///
    /// `sourceCodec` (from ``probe(input:override:)``) gates the copy attempt
    /// rather than the copy being tried unconditionally, because some muxers
    /// accept more than their name suggests: WAV will happily wrap an MP3 stream,
    /// so an unconditional `-acodec copy` would hand back a `.wav` that is really
    /// an MP3 in disguise. When the codec is unknown we re-encode, which is always
    /// correct if not always fastest.
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

    /// The ffmpeg flags each audio target is produced with.
    ///
    /// Deliberately on this side of the module boundary. ``AudioExtractionFormat``
    /// lives in `GoelCore` because the size estimate and the copy decision are
    /// worth testing without a Mac app; the flags that carry those decisions out
    /// are part of launching a process, and `GoelCore` also builds for the Linux
    /// daemon, which never runs one.
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

    /// Run ffmpeg, preferring `copyArgs` and falling back to `encodeArgs`.
    ///
    /// The fallback is taken **only** when the failure output reads as a
    /// container/codec mismatch. Retrying every failure would turn a five-second
    /// error on a truncated source into a twenty-minute re-encode that fails the
    /// same way at the end.
    private static func run(input: URL, outputExtension: String,
                            copyArgs: [String]?, encodeArgs: [String],
                            override: String,
                            cancellation: Cancellation,
                            onProgress: @escaping @Sendable (MediaProgressSample) -> Void)
        async -> Outcome {
        // Surface the SAME explanation the UI uses for the disabled state, rather
        // than a terse "not found — brew install" that is wrong for a user who
        // has no Homebrew and shouldn't need one.
        let exe: URL
        switch resolve(override: override) {
        case .found(let url, _): exe = url
        case .missing(let reason): return .failure(summary: reason, detail: reason)
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            let reason = "The source file is missing."
            return .failure(summary: reason, detail: reason)
        }
        // Claimed only once every reason to abort has been ruled out: the claim
        // creates a real (empty) file, and leaving one of those next to the user's
        // media because ffmpeg turned out to be missing would be its own small bug.
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
                // Fall through to the re-encode. The partial is deliberately NOT
                // deleted here: it is the reservation that stops a concurrent job
                // for a different source from claiming this same output name, and
                // ffmpeg's own `-y` overwrites it on the retry anyway.
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

    /// Why an apparently-successful run did not actually produce a usable file,
    /// or nil when it did.
    ///
    /// ffmpeg can exit 0 having written nothing — a source whose only stream was
    /// filtered out by `-vn` is the everyday case: "extract audio" from a silent
    /// video leaves a zero-byte file and a clean exit code. Reporting that as a
    /// success puts a green card and a Reveal in Finder button on an empty file.
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
        // -y: the output name is already unique, but be explicit. -nostdin so a
        // prompt can never hang the process. -loglevel error keeps stderr small.
        // -progress pipe:1 is the whole point of this rewrite: it makes ffmpeg
        // report where it has got to, on stdout, in a machine-readable form. It
        // used to be discarded to /dev/null, which is why there was no bar to
        // draw. -nostats suppresses the human-readable duplicate on stderr.
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-progress", "pipe:1", "-nostats",
                             "-i", input.path] + extraArgs + [output.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // The reader is stateful (it stitches blocks back together across chunk
        // boundaries) and readabilityHandler fires on an arbitrary queue, so it
        // gets its own lock rather than being touched from two places.
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

    /// The last, most specific part of ffmpeg's complaint, or a plain fallback.
    ///
    /// Truncated from the *end* because ffmpeg puts the actual error last and its
    /// preamble first. The full text is kept by the caller for the "Copy details"
    /// affordance; this is only the one-line summary.
    private static func message(from stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ffmpeg failed." }
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        return String(lastLine.suffix(200))
    }

    /// A never-clobber sibling path: `name.ext`, then `name (1).ext`, … — claimed
    /// atomically so two conversions running at the same time cannot pick it.
    ///
    /// A "does it exist? then use it" check is not enough here. Two different
    /// sources can want the same output name (`talk.mp4` and `talk.mkv` both
    /// convert to `talk.webm`), and with two jobs running concurrently both would
    /// test the name in the same instant, both find it free, and the second
    /// ffmpeg would quietly overwrite the first's work. So the name is claimed by
    /// creating the file with `O_EXCL`: whichever job wins the syscall owns it,
    /// and the loser moves on to the next candidate. ffmpeg's `-y` then overwrites
    /// our zero-byte placeholder, and every failure path deletes it.
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
            // Anything other than "it already exists" means we cannot write here
            // at all (no such directory, read-only volume, no permission). Hand
            // the path back and let ffmpeg produce the real diagnostic — it says
            // *why* far better than we could guess from errno.
            if errno != EEXIST { return candidate }
        }
        // Ten thousand siblings all taken. Returning `base.ext` here would hand
        // back a name we know is occupied and let ffmpeg's `-y` destroy it, so
        // fall through to a name nothing can already hold — ugly, but it is a
        // file that exists rather than one that used to.
        let fallback = dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
        let fd = open(fallback.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 { close(fd) }
        return fallback
    }
}
