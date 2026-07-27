import Foundation

/// Everything about a media conversion that can be decided without launching a
/// process: reading ffmpeg's progress stream, reading a duration out of its
/// banner, turning those into a percentage and an ETA, predicting the output
/// size, and deciding whether a stream copy is worth attempting.
///
/// This lives in `GoelCore` for the same reason ``PlaylistExpander`` and
/// ``MediaFormatTable`` do: the parsing is the part that breaks, and a test that
/// needed ffmpeg installed would be skipped on CI and would therefore protect
/// nothing. `GoelApp/FFmpegService` owns the process plumbing and calls in here
/// for every decision it makes.

// MARK: - Progress stream

/// One reading from ffmpeg's `-progress` stream.
///
/// ffmpeg emits a block of `key=value` lines roughly twice a second, terminated
/// by `progress=continue` (or `progress=end` for the final one). Every field is
/// optional because ffmpeg omits what it has nothing to say about — a stream
/// copy, for instance, often reports no `bitrate`.
public struct MediaProgressSample: Equatable, Sendable {

    /// How far into the *source* ffmpeg has read, in seconds.
    public var outTimeSeconds: Double?

    /// Bytes written to the output so far.
    public var totalSize: Int64?

    /// Encoding rate relative to real time — `1.0` means one second of media per
    /// second of wall clock, `18.0` is a typical stream copy.
    public var speed: Double?

    /// True once ffmpeg has written `progress=end`, i.e. this is the last block.
    public var isFinal: Bool

    public init(outTimeSeconds: Double? = nil, totalSize: Int64? = nil,
                speed: Double? = nil, isFinal: Bool = false) {
        self.outTimeSeconds = outTimeSeconds
        self.totalSize = totalSize
        self.speed = speed
        self.isFinal = isFinal
    }
}

/// Incremental reader for ffmpeg's `-progress` output.
///
/// A pipe read returns whatever bytes happened to be buffered, which lands mid
/// line and mid block far more often than not — so a naive "split on newline and
/// parse" drops or mangles roughly every other reading. This buffers the tail of
/// a partial line and only emits a sample when a block terminator arrives, which
/// is the single most important correctness property of the whole progress path.
public struct MediaProgressReader {

    /// The unterminated tail of the last chunk, waiting for the rest of its line.
    private var carry = ""

    /// Fields accumulated for the block currently being read.
    private var pending = MediaProgressSample()

    /// Whether `pending` has had anything assigned to it since the last emit.
    /// Guards against emitting an all-nil sample from a stray terminator.
    private var pendingHasFields = false

    public init() {}

    /// Feed the next chunk of stdout. Returns one sample per completed block —
    /// usually zero or one, but a slow reader can pick up several at once.
    public mutating func consume(_ chunk: String) -> [MediaProgressSample] {
        var samples: [MediaProgressSample] = []
        let combined = carry + chunk
        // `omittingEmptySubsequences: false` keeps the trailing empty piece that
        // marks "the chunk ended exactly on a newline", so the carry is cleared
        // rather than re-parsed.
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        carry = String(lines.removeLast())
        for line in lines {
            guard let sample = apply(String(line)) else { continue }
            samples.append(sample)
        }
        return samples
    }

    /// Apply one complete line, returning a sample when it terminated a block.
    private mutating func apply(_ line: String) -> MediaProgressSample? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[trimmed.startIndex..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...])
        switch key {
        case "out_time_us", "out_time_ms":
            // Both keys are microseconds. `out_time_ms` is a long-standing ffmpeg
            // misnomer — it has always carried microseconds despite the name, and
            // reading it as milliseconds would report progress 1000× too fast.
            // ffmpeg writes "N/A" before the first frame is muxed.
            if let micros = Double(value) {
                pending.outTimeSeconds = micros / 1_000_000
                pendingHasFields = true
            }
        case "out_time":
            // `HH:MM:SS.ffffff`. Only used when the microsecond keys are absent,
            // so a well-formed block isn't parsed twice with the coarser value.
            if pending.outTimeSeconds == nil, let seconds = Self.seconds(fromTimecode: value) {
                pending.outTimeSeconds = seconds
                pendingHasFields = true
            }
        case "total_size":
            if let bytes = Int64(value), bytes >= 0 {
                pending.totalSize = bytes
                pendingHasFields = true
            }
        case "speed":
            // "1.83x", or "N/A" while ffmpeg is still starting up.
            let numeric = value.hasSuffix("x") ? String(value.dropLast()) : value
            if let rate = Double(numeric.trimmingCharacters(in: .whitespaces)), rate > 0 {
                pending.speed = rate
                pendingHasFields = true
            }
        case "progress":
            guard pendingHasFields || value == "end" else { return nil }
            var sample = pending
            sample.isFinal = (value == "end")
            pending = MediaProgressSample()
            pendingHasFields = false
            return sample
        default:
            break
        }
        return nil
    }

    /// `HH:MM:SS.ff` → seconds. Also accepts `MM:SS.ff` and a bare seconds value,
    /// because ffmpeg's banner is not consistent across builds.
    public static func seconds(fromTimecode raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.uppercased() != "N/A" else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count <= 3 else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

// MARK: - Duration

public enum MediaDuration {

    /// Pull the source length out of ffmpeg's own banner.
    ///
    /// `ffmpeg -i file` prints `Duration: 00:11:02.34, start: …` to **stderr** and
    /// exits non-zero when no output is given — that non-zero exit is expected and
    /// must not be read as a failure. This is the fallback for containers
    /// AVFoundation cannot open (MKV, WebM), which is most of what a downloader
    /// ends up holding.
    public static func parse(banner: String) -> Double? {
        for line in banner.split(separator: "\n") {
            guard let range = line.range(of: "Duration:") else { continue }
            let rest = line[range.upperBound...]
            let field = rest.split(separator: ",").first.map(String.init) ?? String(rest)
            // A stream with no known length prints "Duration: N/A" — which must
            // stay nil rather than becoming a zero that reads as "instant".
            if let seconds = MediaProgressReader.seconds(fromTimecode: field), seconds > 0 {
                return seconds
            }
        }
        return nil
    }

    /// The first audio stream's codec name from the same banner, e.g. `aac`.
    ///
    /// The line reads
    /// `Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, …`
    /// and only the bare codec name is wanted — the profile in parentheses and
    /// the fourcc are noise for the copy decision.
    ///
    /// Returns nil when there is no audio stream at all, which is a meaningful
    /// answer: extracting audio from a silent video should fail early with a
    /// sentence rather than after a pointless ffmpeg run.
    public static func audioCodec(banner: String) -> String? {
        for line in banner.split(separator: "\n") {
            guard line.contains("Stream #"), let range = line.range(of: "Audio: ") else { continue }
            let rest = line[range.upperBound...]
            let name = rest.prefix { !" ,(".contains($0) }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed.lowercased() }
        }
        return nil
    }
}

// MARK: - Derived numbers

public enum MediaEstimate {

    /// Completed fraction, clamped to `0…1`.
    ///
    /// Returns nil when the total is unknown or zero — the UI must then show an
    /// indeterminate bar and say the length is unknown rather than display an
    /// invented percentage. The clamp matters: container durations are frequently
    /// a few tenths short of the real stream, so an unclamped ratio parks at
    /// "103%" for the last second of every job.
    public static func fraction(processed: Double, total: Double?) -> Double? {
        guard let total, total > 0, processed.isFinite, processed >= 0 else { return nil }
        return min(1, processed / total)
    }

    /// Seconds of wall clock remaining, or nil when there is nothing honest to
    /// say yet.
    ///
    /// Uses ffmpeg's own `speed` (media-seconds per wall-second) rather than a
    /// rate derived from elapsed time, so the estimate is right from the second
    /// reading instead of converging over the first minute. Nil at 0% and at
    /// completion — "∞ remaining" and "0s remaining" are both noise.
    public static func eta(processed: Double, total: Double?, speed: Double?) -> Double? {
        guard let total, total > 0, let speed, speed > 0 else { return nil }
        let remaining = total - processed
        guard remaining > 0.5 else { return nil }
        return remaining / speed
    }
}

// MARK: - Audio extraction targets

/// The audio containers offered in the UI, plus the facts needed to size a job
/// and to decide whether it can be done without re-encoding.
///
/// Here rather than in `GoelApp` so the size estimate and the copy decision are
/// testable on CI, where there is neither a Mac app nor an ffmpeg. The *arguments*
/// that realise those decisions are not here: building a command line is process
/// plumbing, it belongs beside the code that spawns the process, and this module
/// also builds for the Linux daemon, which has no business knowing ffmpeg's flags.
public enum AudioExtractionFormat: String, CaseIterable, Sendable {
    case mp3, m4a, flac, wav

    public var displayName: String { rawValue.uppercased() }

    /// Roughly how many bytes one second of output occupies, for the size hint
    /// shown in the menu and the free-space pre-flight.
    ///
    /// Deliberately approximate and deliberately **generous** for the lossy
    /// formats: the number's job is to stop someone writing 1.2 GB of WAV onto a
    /// disk with 400 MB free, and an estimate that undershoots fails at exactly
    /// that job. Figures are for 44.1 kHz stereo.
    public var approximateBytesPerSecond: Double {
        switch self {
        case .mp3:  return 24_000      // libmp3lame -q:a 2 ≈ 190 kbit/s VBR
        case .m4a:  return 24_000      // 192 kbit/s
        case .flac: return 105_000     // ≈ 60% of 16-bit PCM
        case .wav:  return 176_400     // 44 100 × 2 ch × 2 bytes
        }
    }

    /// Estimated output size in bytes, or nil when the source length is unknown.
    public func estimatedBytes(durationSeconds: Double?) -> Int64? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return Int64(durationSeconds * approximateBytesPerSecond)
    }

    /// Whether an already-decoded source track of `codec` can be lifted into this
    /// container verbatim, with no re-encode and no generation loss.
    ///
    /// Codec names are ffprobe/ffmpeg's own (`aac`, `mp3`, `flac`, `pcm_s16le`),
    /// compared case-insensitively. Unknown or empty means "don't assume" — the
    /// caller then attempts a copy anyway and falls back, so a wrong answer here
    /// costs a wasted sub-second process launch, never a wrong output file.
    public func canCopy(sourceCodec: String?) -> Bool {
        guard let raw = sourceCodec?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return false }
        switch self {
        case .mp3:  return raw == "mp3"
        case .m4a:  return raw == "aac" || raw == "alac"
        case .flac: return raw == "flac"
        // PCM into WAV is only a copy when the sample format already matches what
        // the encoder would produce; anything else (24-bit, float, or any lossy
        // codec) has to be converted.
        case .wav:  return raw == "pcm_s16le"
        }
    }
}

// MARK: - Container conversion

public enum MediaContainer {

    /// Containers Goel° offers as conversion targets.
    public static let convertTargets = ["mp4", "mkv", "webm", "mov"]

    /// Whether a stream copy is *likely* to work going from one container to
    /// another — used only to label the menu ("copy, instant"), never to decide
    /// what ffmpeg is actually asked to do.
    ///
    /// The real decision is made by running ffmpeg with `-c copy` and falling back
    /// to a re-encode if the muxer rejects the codec, because no static table can
    /// know what codecs a given file actually holds. This function exists so the
    /// common cases can be *labelled* honestly before the user commits.
    public static func likelyStreamCopy(from source: String, to target: String) -> Bool {
        let from = source.lowercased(), to = target.lowercased()
        guard from != to else { return true }
        // MP4/MOV/MKV are all happy with the H.264/H.265 + AAC families that make
        // up essentially everything this app downloads. WebM is the odd one out:
        // it accepts only VP8/VP9/AV1 + Vorbis/Opus, so anything crossing into or
        // out of it is a re-encode far more often than not.
        let broad: Set<String> = ["mp4", "mov", "mkv", "m4v"]
        return broad.contains(from) && broad.contains(to)
    }

    /// Whether ffmpeg's failure output reads as "this codec can't go in that
    /// container", which is the one failure a re-encode retry can fix.
    ///
    /// Matching on message text is unlovely, but ffmpeg returns exit status 1 for
    /// every failure and offers nothing more structured. The alternative — always
    /// retrying — would run a full re-encode after a genuine failure such as a
    /// truncated source, turning a five-second error into a twenty-minute one.
    public static func isCodecIncompatibility(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        // Each marker is a phrase ffmpeg only produces when a muxer has refused a
        // stream it was handed verbatim. Kept narrow on purpose: a loose match
        // here spends a full re-encode on a file that was never going to convert.
        let markers = [
            // mp4/mov: "Could not find tag for codec vorbis in stream #1,
            // codec not currently supported in container"
            "could not find tag for codec",
            "codec not currently supported in container",
            // webm: "Only VP8 or VP9 or AV1 video and Vorbis or Opus audio …
            // are supported for WebM."
            "are supported for",
            // "Subtitle codec 0x1000 is not supported in this container"
            "is not supported in",
            // "Could not write header … (incorrect codec parameters ?)"
            "incorrect codec parameters",
        ]
        return markers.contains { text.contains($0) }
    }
}

// MARK: - Stall detection

public enum MediaStall {

    /// How long ffmpeg may report no forward progress before the UI flags it.
    ///
    /// Replaces a blind 30-minute kill. That timer murdered legitimate long
    /// transcodes and let genuinely wedged ones sit for the full half hour, and
    /// because it terminated the process itself the resulting message was the
    /// generic "ffmpeg failed" — the user was told the wrong thing either way.
    public static let threshold: TimeInterval = 300

    /// Whether a job that last advanced at `lastAdvance` should be flagged.
    public static func isStalled(lastAdvance: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastAdvance) >= threshold
    }

    /// How long a *cancel* may be outstanding before the UI stops promising it is
    /// about to happen. The app sends SIGTERM, waits two seconds, then SIGKILLs;
    /// past this a SIGKILL has landed and the process still hasn't exited, which
    /// means it is blocked somewhere no signal reaches.
    public static let stopGrace: TimeInterval = 6

    /// Whether a cancel requested at `requestedAt` has gone unanswered too long.
    public static func isStopStuck(requestedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(requestedAt) > stopGrace
    }
}
