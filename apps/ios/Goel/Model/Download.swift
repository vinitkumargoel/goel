import Foundation

/// One transfer, and everything the UI, the engine, and the widgets need to know about it.
///
/// This is the single domain type for the app. It is a value type on purpose: the store owns
/// the array, views read snapshots of it, and the engine hands back whole updated values.
///
/// Every derived number on this type is finite. `NaN` and `inf` are the two values that reach
/// a `Text` and render as literal "nan"/"inf" in front of a user, so they are filtered at the
/// source rather than at every call site.
public struct Download: Identifiable, Codable, Sendable, Equatable, Hashable {

    // MARK: - Kind

    /// The transport a download uses. Deliberately closed.
    ///
    /// There is no `.torrent` case. `docs/PRD-iOS.md` §8.1 excludes BitTorrent as a product
    /// decision under App Review Guideline 1.4.3. Do not add one "just in case" — the widget
    /// token strings and the App Intents surface both enumerate this type.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case http
        case https
        case ftp
        case sftp
        case hls

        /// The short lowercase label the row subtitle and the widgets print (`"sftp"`).
        /// Kept as a plain `String` so `SharedSnapshot` can carry it without importing this file.
        public var token: String { rawValue }

        /// SF Symbol for the row icon. All of these exist at the iOS 18 deployment target.
        public var systemImage: String {
            switch self {
            case .http: "globe"
            case .https: "lock.fill"
            case .ftp: "folder.fill"
            case .sftp: "lock.shield.fill"
            case .hls: "play.rectangle.fill"
            }
        }

        /// Best guess from a URL. Playlist extensions win over the scheme, because an HLS
        /// manifest is served over https and behaves nothing like a file download.
        public static func infer(from url: URL) -> Kind {
            switch url.pathExtension.lowercased() {
            case "m3u8", "m3u": return .hls
            default: break
            }
            switch url.scheme?.lowercased() {
            case "http": return .http
            case "https": return .https
            case "ftp", "ftps": return .ftp
            case "sftp", "ssh", "scp": return .sftp
            default: return .https
            }
        }
    }

    // MARK: - Status

    public enum Status: String, Codable, Sendable, CaseIterable {
        case queued
        case probing
        case downloading
        case paused
        case waitingForWiFi
        case verifying
        case completed
        case failed

        /// Bytes are (or are about to be) moving. Drives the ember tint and the Live Activity.
        public var isActive: Bool {
            self == .downloading || self == .probing || self == .verifying
        }

        /// The transfer will not change again without user action.
        public var isTerminal: Bool {
            self == .completed || self == .failed
        }

        public var displayName: String {
            switch self {
            case .queued: "Queued"
            case .probing: "Probing"
            case .downloading: "Downloading"
            case .paused: "Paused"
            // U+2011 non-breaking hyphen: "Wi‑Fi" must never wrap mid-word in a narrow row.
            case .waitingForWiFi: "Waiting for Wi\u{2011}Fi"
            case .verifying: "Verifying"
            case .completed: "Completed"
            case .failed: "Failed"
            }
        }
    }

    // MARK: - Segment

    /// One byte range of the file, owned by one connection.
    ///
    /// `range` is **inclusive on both ends** — `0...99` is one hundred bytes, and that is also
    /// exactly how HTTP `Range:` headers count. Do not switch it to a half-open range without
    /// fixing every `Range:` header in the engine.
    public struct Segment: Codable, Sendable, Identifiable, Equatable, Hashable {
        public var id: Int
        public var range: ClosedRange<Int64>
        public var receivedBytes: Int64
        public var isActive: Bool

        public init(id: Int, range: ClosedRange<Int64>, receivedBytes: Int64 = 0, isActive: Bool = false) {
            self.id = id
            self.range = range
            self.receivedBytes = receivedBytes
            self.isActive = isActive
        }

        /// Inclusive length: `upper - lower + 1`.
        public var totalBytes: Int64 {
            range.upperBound - range.lowerBound + 1
        }

        /// 0…1, never `NaN`.
        public var fraction: Double {
            let total = totalBytes
            guard total > 0 else { return 0 }
            let f = Double(receivedBytes) / Double(total)
            guard f.isFinite else { return 0 }
            return min(max(f, 0), 1)
        }

        public var isComplete: Bool {
            receivedBytes >= totalBytes
        }

        /// The next byte this segment needs, or `nil` when complete.
        /// A segment always streams forward from `range.lowerBound`, so its received bytes are
        /// a contiguous prefix and the cursor is simply lower + received.
        public var cursor: Int64? {
            isComplete ? nil : range.lowerBound + receivedBytes
        }
    }

    // MARK: - Stored

    public var id: UUID
    public var url: URL
    public var filename: String
    public var saveDirectory: String
    public var kind: Kind
    public var status: Status
    /// `nil` when the server did not report a length. Everything derived from it must cope.
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var segments: [Segment]
    /// Bounded ring buffer, newest last, at most ``speedSampleLimit`` entries.
    /// Unbounded here is a memory leak that only shows up on a multi-hour transfer.
    public var speedSamples: [Double]
    public var addedAt: Date
    public var completedAt: Date?
    public var checksumVerified: Bool
    /// T10 — the file is written in order so it can be played while it downloads.
    public var isSequential: Bool
    /// The server advertised `Accept-Ranges: bytes`.
    public var supportsResume: Bool
    public var errorMessage: String?
    /// `ETag` or `Last-Modified`, replayed as `If-Range` on resume (T05/T06) so a changed
    /// file on the server produces a fresh 200 instead of a silently corrupt splice.
    public var validator: String?

    /// How many speed samples the ring buffer keeps — 60, one minute at 1 Hz, which is
    /// exactly what the detail sparkline draws.
    public static let speedSampleLimit = 60

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        saveDirectory: String,
        kind: Kind,
        status: Status = .queued,
        totalBytes: Int64? = nil,
        receivedBytes: Int64 = 0,
        segments: [Segment] = [],
        speedSamples: [Double] = [],
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        checksumVerified: Bool = false,
        isSequential: Bool = false,
        supportsResume: Bool = false,
        errorMessage: String? = nil,
        validator: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.saveDirectory = saveDirectory
        self.kind = kind
        self.status = status
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.segments = segments
        self.speedSamples = Array(speedSamples.filter(\.isFinite).suffix(Self.speedSampleLimit))
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.checksumVerified = checksumVerified
        self.isSequential = isSequential
        self.supportsResume = supportsResume
        self.errorMessage = errorMessage
        self.validator = validator
    }

    // MARK: - Derived

    /// The host the bytes are coming from. The detail screen prints it verbatim.
    public var sourceHost: String { url.host ?? "" }

    /// 0…1. `0` when the length is unknown or zero — never `NaN`.
    public var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        let f = Double(receivedBytes) / Double(total)
        guard f.isFinite else { return 0 }
        return min(max(f, 0), 1)
    }

    /// Mean of the last three samples, smoothing the per-tick jitter out of the row subtitle.
    /// `0` when there are no samples.
    public var currentSpeed: Double {
        let window = speedSamples.suffix(3)
        guard !window.isEmpty else { return 0 }
        let sum = window.reduce(0, +)
        guard sum.isFinite else { return 0 }
        let mean = sum / Double(window.count)
        return mean.isFinite && mean > 0 ? mean : 0
    }

    /// Seconds remaining, or `nil` when the speed is zero or the size is unknown.
    /// Never `inf` — a division by a zero speed is caught before it can reach a formatter.
    public var eta: TimeInterval? {
        let speed = currentSpeed
        guard speed > 0, totalBytes != nil else { return nil }
        let remaining = remainingBytes
        guard remaining > 0 else { return 0 }
        let seconds = Double(remaining) / speed
        guard seconds.isFinite else { return nil }
        return seconds
    }

    /// Bytes still to fetch. `0` when the length is unknown.
    public var remainingBytes: Int64 {
        guard let total = totalBytes else { return 0 }
        return max(0, total - receivedBytes)
    }

    /// The end of the contiguous run of bytes starting at 0 — T06's critical value.
    ///
    /// This is emphatically **not** `receivedBytes`. With six segments sitting at
    /// 100/78/64/57/41/22 % the sum of their received bytes is around 60 % of the file, but
    /// only the leading run is actually usable: everything past the first incomplete segment
    /// is separated from byte 0 by a hole. Handing a background `URLSession` the sum as a
    /// resume offset splices a hole into the file.
    ///
    /// Each segment streams forward from its own `range.lowerBound`, so the first incomplete
    /// segment still contributes its own received prefix before the walk stops.
    public var contiguousPrefix: Int64 {
        guard !segments.isEmpty else { return min(receivedBytes, totalBytes ?? receivedBytes) }
        var cursor: Int64 = 0
        for segment in segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            // A gap between the run so far and this segment ends the prefix.
            guard segment.range.lowerBound <= cursor else { break }
            let reach = segment.range.lowerBound + max(0, min(segment.receivedBytes, segment.totalBytes))
            cursor = max(cursor, reach)
            guard segment.isComplete else { break }
        }
        return cursor
    }

    // MARK: - Mutation

    /// Appends a speed sample, dropping non-finite values and keeping the buffer bounded.
    public mutating func recordSpeedSample(_ v: Double) {
        guard v.isFinite else { return }
        speedSamples.append(max(0, v))
        if speedSamples.count > Self.speedSampleLimit {
            speedSamples.removeFirst(speedSamples.count - Self.speedSampleLimit)
        }
    }

    // MARK: - Coding

    /// Pinned coders. Foundation's default date strategy is seconds-since-2001, a silent
    /// 31-year offset the moment anything else reads the file. This matches
    /// `GoelFacade.makeEncoder()` on the desktop side: sorted keys, Unix seconds.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
