import Foundation

public struct MediaProgressSample: Equatable, Sendable {

    public var outTimeSeconds: Double?

    public var totalSize: Int64?

    public var speed: Double?

    public var isFinal: Bool

    public init(outTimeSeconds: Double? = nil, totalSize: Int64? = nil,
                speed: Double? = nil, isFinal: Bool = false) {
        self.outTimeSeconds = outTimeSeconds
        self.totalSize = totalSize
        self.speed = speed
        self.isFinal = isFinal
    }
}

/// Pipe reads land mid-line and mid-block: without this buffering every other reading is mangled.
public struct MediaProgressReader {

    private var carry = ""

    private var pending = MediaProgressSample()

    /// Guards against emitting an all-nil sample from a stray terminator.
    private var pendingHasFields = false

    public init() {}

    public mutating func consume(_ chunk: String) -> [MediaProgressSample] {
        var samples: [MediaProgressSample] = []
        let combined = carry + chunk
        // `omittingEmptySubsequences: false` marks "ended on a newline", so the carry clears instead of re-parsing.
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        carry = String(lines.removeLast())
        for line in lines {
            guard let sample = apply(String(line)) else { continue }
            samples.append(sample)
        }
        return samples
    }

    private mutating func apply(_ line: String) -> MediaProgressSample? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[trimmed.startIndex..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...])
        switch key {
        case "out_time_us", "out_time_ms":
            // Both keys are microseconds — `out_time_ms` is an ffmpeg misnomer; ms would be 1000× too fast.
            if let micros = Double(value) {
                pending.outTimeSeconds = micros / 1_000_000
                pendingHasFields = true
            }
        case "out_time":
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

public enum MediaDuration {

    /// The banner is on stderr and `ffmpeg -i` exits non-zero — that is expected, not a failure.
    public static func parse(banner: String) -> Double? {
        for line in banner.split(separator: "\n") {
            guard let range = line.range(of: "Duration:") else { continue }
            let rest = line[range.upperBound...]
            let field = rest.split(separator: ",").first.map(String.init) ?? String(rest)
            // "Duration: N/A" must stay nil, not become a zero that reads as "instant".
            if let seconds = MediaProgressReader.seconds(fromTimecode: field), seconds > 0 {
                return seconds
            }
        }
        return nil
    }

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

public enum MediaEstimate {

    /// Clamped: container durations run a few tenths short, so unclamped this parks at "103%".
    public static func fraction(processed: Double, total: Double?) -> Double? {
        guard let total, total > 0, processed.isFinite, processed >= 0 else { return nil }
        return min(1, processed / total)
    }

    public static func eta(processed: Double, total: Double?, speed: Double?) -> Double? {
        guard let total, total > 0, let speed, speed > 0 else { return nil }
        let remaining = total - processed
        guard remaining > 0.5 else { return nil }
        return remaining / speed
    }
}

public enum AudioExtractionFormat: String, CaseIterable, Sendable {
    case mp3, m4a, flac, wav

    public var displayName: String { rawValue.uppercased() }

    /// Deliberately generous (44.1 kHz stereo): an undershoot lets 1.2 GB land on 400 MB free.
    public var approximateBytesPerSecond: Double {
        switch self {
        case .mp3:  return 24_000
        case .m4a:  return 24_000
        case .flac: return 105_000
        case .wav:  return 176_400
        }
    }

    public func estimatedBytes(durationSeconds: Double?) -> Int64? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return Int64(durationSeconds * approximateBytesPerSecond)
    }

    public func canCopy(sourceCodec: String?) -> Bool {
        guard let raw = sourceCodec?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return false }
        switch self {
        case .mp3:  return raw == "mp3"
        case .m4a:  return raw == "aac" || raw == "alac"
        case .flac: return raw == "flac"
        // Only this exact sample format copies; 24-bit, float or lossy must be converted.
        case .wav:  return raw == "pcm_s16le"
        }
    }
}

public enum MediaContainer {

    public static let convertTargets = ["mp4", "mkv", "webm", "mov"]

    /// A menu label only — the real decision is ffmpeg `-c copy` with a re-encode fallback.
    public static func likelyStreamCopy(from source: String, to target: String) -> Bool {
        let from = source.lowercased(), to = target.lowercased()
        guard from != to else { return true }
        let broad: Set<String> = ["mp4", "mov", "mkv", "m4v"]
        return broad.contains(from) && broad.contains(to)
    }

    public static func isCodecIncompatibility(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        // Narrow on purpose: a loose match spends a full re-encode on a file that was never convertible.
        let markers = [
            "could not find tag for codec",
            "codec not currently supported in container",
            "are supported for",
            "is not supported in",
            "incorrect codec parameters",
        ]
        return markers.contains { text.contains($0) }
    }
}

public enum MediaStall {

    public static let threshold: TimeInterval = 300

    public static func isStalled(lastAdvance: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastAdvance) >= threshold
    }

    /// Must outlast the SIGTERM → 2s → SIGKILL sequence; past this no signal will reach the process.
    public static let stopGrace: TimeInterval = 6

    public static func isStopStuck(requestedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(requestedAt) > stopGrace
    }
}
