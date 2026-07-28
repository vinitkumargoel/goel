import Foundation

/// Every media-conversion decision needing no process: ffmpeg progress/duration parsing, percentage, ETA,
/// size prediction, copy viability. In Core so it is CI-testable; `GoelApp/FFmpegService` does the process.

// MARK: - Progress stream

/// One reading from ffmpeg's `-progress` stream: `key=value` lines ~2×/sec ending `progress=continue`
/// (or `=end`). Every field is optional — ffmpeg omits what it has nothing to say about.
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

/// Incremental reader for ffmpeg's `-progress` output. Pipe reads land mid-line and mid-block, so this
/// buffers the partial tail and emits only on a block terminator — else every other reading is mangled.
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
        // `omittingEmptySubsequences: false` keeps the trailing empty piece marking "chunk ended exactly
        // on a newline", so the carry is cleared rather than re-parsed.
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
            // Both keys are microseconds: `out_time_ms` is a long-standing ffmpeg misnomer, and reading
            // it as milliseconds reports progress 1000× too fast. "N/A" before the first frame is muxed.
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

    /// Source length from `ffmpeg -i`'s banner (`Duration: 00:11:02.34, …` on **stderr**; its non-zero
    /// exit is expected, not a failure). Fallback for the MKV/WebM that AVFoundation cannot open.
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

    /// First audio stream's bare codec name from the banner's `Audio: aac (LC) (mp4a…)` — profile and
    /// fourcc are noise for the copy decision. Nil means no audio stream: fail early, not after ffmpeg.
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

    /// Completed fraction clamped to `0…1` — container durations run a few tenths short, so unclamped it
    /// parks at "103%". Nil when the total is unknown or zero, so the UI shows an indeterminate bar.
    public static func fraction(processed: Double, total: Double?) -> Double? {
        guard let total, total > 0, processed.isFinite, processed >= 0 else { return nil }
        return min(1, processed / total)
    }

    /// Wall-clock seconds remaining. Uses ffmpeg's own `speed` (media-s per wall-s), not a rate derived
    /// from elapsed time, so it is right from the second reading. Nil at 0% and at completion: noise.
    public static func eta(processed: Double, total: Double?, speed: Double?) -> Double? {
        guard let total, total > 0, let speed, speed > 0 else { return nil }
        let remaining = total - processed
        guard remaining > 0.5 else { return nil }
        return remaining / speed
    }
}

// MARK: - Audio extraction targets

/// Audio containers offered in the UI, plus what is needed to size a job and judge a copy. In Core, not
/// `GoelApp`, so it is CI-testable without ffmpeg; command lines stay beside the code that spawns them.
public enum AudioExtractionFormat: String, CaseIterable, Sendable {
    case mp3, m4a, flac, wav

    public var displayName: String { rawValue.uppercased() }

    /// Bytes per second of output, for the menu size hint and free-space pre-flight. Deliberately
    /// **generous** for lossy formats — an undershoot lets 1.2 GB land on 400 MB free. 44.1 kHz stereo.
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

    /// Whether a source track can be lifted into this container verbatim — no re-encode, no generation
    /// loss. Codec names are ffmpeg's, case-insensitive; unknown means "don't assume", caller falls back.
    public func canCopy(sourceCodec: String?) -> Bool {
        guard let raw = sourceCodec?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return false }
        switch self {
        case .mp3:  return raw == "mp3"
        case .m4a:  return raw == "aac" || raw == "alac"
        case .flac: return raw == "flac"
        // PCM into WAV copies only when the sample format already matches the encoder's output;
        // 24-bit, float, or any lossy codec has to be converted.
        case .wav:  return raw == "pcm_s16le"
        }
    }
}

// MARK: - Container conversion

public enum MediaContainer {

    /// Containers Goel° offers as conversion targets.
    public static let convertTargets = ["mp4", "mkv", "webm", "mov"]

    /// Whether a container-to-container stream copy is *likely* — labels the menu ("copy, instant") only.
    /// The real decision is ffmpeg `-c copy` with a re-encode fallback; no static table knows the codecs.
    public static func likelyStreamCopy(from source: String, to target: String) -> Bool {
        let from = source.lowercased(), to = target.lowercased()
        guard from != to else { return true }
        // MP4/MOV/MKV all accept the H.264/H.265 + AAC families that dominate here; WebM takes only
        // VP8/VP9/AV1 + Vorbis/Opus, so crossing into or out of it is usually a re-encode.
        let broad: Set<String> = ["mp4", "mov", "mkv", "m4v"]
        return broad.contains(from) && broad.contains(to)
    }

    /// Whether ffmpeg's stderr reads as "codec can't go in that container" — the one failure a re-encode
    /// retry fixes. Text matching because every failure exits 1; retrying blindly costs 20 min on a dud.
    public static func isCodecIncompatibility(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        // Each marker is a phrase ffmpeg emits only when a muxer refused a stream handed to it verbatim.
        // Narrow on purpose: a loose match spends a full re-encode on a file that was never convertible.
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

    /// How long ffmpeg may report no forward progress before the UI flags it. Replaces a blind 30-minute
    /// kill that murdered long transcodes, waited out wedged ones, and only ever said "ffmpeg failed".
    public static let threshold: TimeInterval = 300

    /// Whether a job that last advanced at `lastAdvance` should be flagged.
    public static func isStalled(lastAdvance: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastAdvance) >= threshold
    }

    /// How long a *cancel* may go unanswered before the UI stops promising it. SIGTERM, 2s, SIGKILL —
    /// past this the SIGKILL has landed and the process is blocked somewhere no signal reaches.
    public static let stopGrace: TimeInterval = 6

    /// Whether a cancel requested at `requestedAt` has gone unanswered too long.
    public static func isStopStuck(requestedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(requestedAt) > stopGrace
    }
}
