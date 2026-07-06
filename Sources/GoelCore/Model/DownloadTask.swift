import Foundation

/// The unified task model both engines present upward.
///
/// It carries up/down byte counts and speeds, a multi-file list, a pre-metadata
/// state (`totalBytes == nil`), a persistable status with a concrete failure
/// reason, and a distinct seeding state — the requirements from the brief.
public struct DownloadTask: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var source: DownloadSource
    public var name: String
    public var saveDirectory: String

    /// Total payload size. `nil` while unknown (magnet pre-metadata, or an HTTP
    /// response with no Content-Length).
    public var totalBytes: Int64?

    public var bytesDownloaded: Int64
    public var bytesUploaded: Int64
    public var downloadSpeed: Double   // bytes/sec
    public var uploadSpeed: Double     // bytes/sec

    public var status: DownloadStatus
    public var priority: FilePriority  // task-level priority within the queue
    public var files: [TransferFile]
    public var connectionCount: Int

    public var addedAt: Date
    public var completedAt: Date?

    /// Resume metadata supplied by the engine (HTTP ETag/range cursor, or a
    /// torrent fast-resume blob). Opaque to the rest of the app.
    public var resumeData: Data?

    /// An optional integrity hash the finished file must match. When set, the
    /// engine verifies the payload before marking the task complete; a mismatch
    /// fails it with ``DownloadError/checksumMismatch``. `nil` = no verification.
    public var expectedChecksum: Checksum?

    /// Live per-connection snapshots (HTTP segments / torrent peers) for the
    /// detail panel. Transient — refreshed by the engine while transferring,
    /// meaningless after relaunch. Optional so old persisted blobs still decode.
    public var connections: [TaskConnection]?

    /// Seeds available in the swarm (torrents only), from the live session.
    public var seedCount: Int?

    /// Real facts about the remote HTTP server (Server/ETag/Accept-Ranges/MIME).
    public var remoteInfo: RemoteInfo?

    /// Result of the post-completion antivirus screen: `"clean"`, `"flagged"`,
    /// or nil when no scan ran (disabled, or still in flight).
    public var scanVerdict: String?

    /// Optional per-task download cap in bytes/sec (0 or nil = no per-task cap;
    /// the global profile ceiling always applies on top).
    public var speedLimitBytesPerSec: Int64?

    /// Download pieces in order (torrents) so media files become playable while
    /// still transferring. nil/false = rarest-first (default).
    public var sequentialDownload: Bool?

    /// When set on a paused task, the scheduler starts it automatically at (or
    /// shortly after) this time. Cleared the moment the task starts — manually
    /// or on schedule. Survives relaunch.
    public var scheduledAt: Date?

    /// Alternative URLs serving the same file (HTTP only). Segments spread
    /// across them and fail over when one misbehaves; every response is checked
    /// against the primary's size so a divergent mirror is dropped, not merged.
    public var mirrors: [String]?

    /// The torrent's v1 info-hash (hex), resolved from libtorrent so it is known
    /// for `.torrent` files too — not just magnet links. nil for non-torrents.
    public var infoHash: String?

    /// Live tracker status (torrents only), refreshed by the session. Transient —
    /// meaningless after relaunch. Optional so old persisted blobs still decode.
    public var trackers: [TorrentTracker]?

    /// A downsampled piece-availability map (torrents only): each value is the
    /// fraction 0…1 of the real pieces in that bucket that are downloaded. Drives
    /// the Progress tab's piece grid with true data. Transient.
    public var pieceAvailability: [Double]?

    /// Optional per-task upload cap in bytes/sec (torrents; 0 or nil = uncapped).
    public var uploadLimitBytesPerSec: Int64?

    /// Stop seeding once the share ratio reaches this value (torrents). nil = seed
    /// indefinitely (until the user stops it or a global rule applies).
    public var seedRatioLimit: Double?

    /// A free-form category the user assigns for grouping/filtering. nil = none.
    /// Retained for back-compat; the multi-tag ``tags`` field supersedes it and
    /// the UI treats a legacy `label` as one more tag.
    public var label: String?

    /// User-assigned tags for grouping/filtering (many per task). nil/empty = none.
    public var tags: [String]?

    /// A free-form note the user attaches to the download. nil = none.
    public var note: String?

    /// A `Referer` header sent with the HTTP(S) request for this task (some hosts
    /// gate downloads on it). Captured from the browser extension or entered by
    /// the user. Only ever sent to the same origin as the download URL. nil = none.
    public var referer: String?

    /// Extra request headers (name → value) sent with the HTTP(S) request for this
    /// task. Reserved header names (Host, Content-Length, …) are ignored by the
    /// engine. nil/empty = none.
    public var requestHeaders: [String: String]?

    /// How many times the scheduler has already auto-retried this download in
    /// the current failure streak (see ``AppSettings/autoRetryEnabled``). Reset
    /// to nil on a successful completion or a manual retry. Optional so old
    /// persisted blobs decode unchanged.
    public var retryAttempt: Int?

    /// File indices the user deselected on the add screen (torrents), before the
    /// per-file list exists. Applied once as `.skip` the moment metadata resolves
    /// (after which the skip lives in each file's own `.priority`), then dropped:
    /// the engine clears its copy after the first apply, and changing a file's
    /// priority scrubs that id here — so re-enabling a file is never undone by a
    /// later resume/relaunch re-applying a stale add-time skip.
    public var initialSkipFileIDs: [Int]?

    public init(
        id: UUID = UUID(),
        source: DownloadSource,
        name: String,
        saveDirectory: String,
        totalBytes: Int64? = nil,
        bytesDownloaded: Int64 = 0,
        bytesUploaded: Int64 = 0,
        downloadSpeed: Double = 0,
        uploadSpeed: Double = 0,
        status: DownloadStatus = .queued,
        priority: FilePriority = .normal,
        files: [TransferFile] = [],
        connectionCount: Int = 0,
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        resumeData: Data? = nil,
        expectedChecksum: Checksum? = nil,
        connections: [TaskConnection]? = nil,
        seedCount: Int? = nil,
        remoteInfo: RemoteInfo? = nil,
        scanVerdict: String? = nil,
        speedLimitBytesPerSec: Int64? = nil,
        sequentialDownload: Bool? = nil,
        scheduledAt: Date? = nil,
        mirrors: [String]? = nil,
        infoHash: String? = nil,
        trackers: [TorrentTracker]? = nil,
        pieceAvailability: [Double]? = nil,
        uploadLimitBytesPerSec: Int64? = nil,
        seedRatioLimit: Double? = nil,
        label: String? = nil,
        tags: [String]? = nil,
        note: String? = nil,
        referer: String? = nil,
        requestHeaders: [String: String]? = nil,
        retryAttempt: Int? = nil,
        initialSkipFileIDs: [Int]? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.saveDirectory = saveDirectory
        self.totalBytes = totalBytes
        self.bytesDownloaded = bytesDownloaded
        self.bytesUploaded = bytesUploaded
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
        self.status = status
        self.priority = priority
        self.files = files
        self.connectionCount = connectionCount
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.resumeData = resumeData
        self.expectedChecksum = expectedChecksum
        self.connections = connections
        self.seedCount = seedCount
        self.remoteInfo = remoteInfo
        self.scanVerdict = scanVerdict
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.sequentialDownload = sequentialDownload
        self.scheduledAt = scheduledAt
        self.mirrors = mirrors
        self.infoHash = infoHash
        self.trackers = trackers
        self.pieceAvailability = pieceAvailability
        self.uploadLimitBytesPerSec = uploadLimitBytesPerSec
        self.seedRatioLimit = seedRatioLimit
        self.label = label
        self.tags = tags
        self.note = note
        self.referer = referer
        self.requestHeaders = requestHeaders
        self.retryAttempt = retryAttempt
        self.initialSkipFileIDs = initialSkipFileIDs
    }

    /// The union of ``tags`` and any legacy ``label``, de-duplicated, order-stable.
    /// The one list the UI should show and filter on.
    public var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in (tags ?? []) + [label].compactMap({ $0 }) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: Derived

    public var kind: DownloadKind { source.kind }

    public var hasMetadata: Bool { totalBytes != nil }

    public var isMultiFile: Bool { files.count > 1 }

    public var fractionCompleted: Double {
        if status.hasData { return 1 }
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(total))
    }

    /// Bytes uploaded divided by bytes downloaded (the seeding ratio).
    public var shareRatio: Double {
        guard bytesDownloaded > 0 else { return 0 }
        return Double(bytesUploaded) / Double(bytesDownloaded)
    }

    /// Connected peers that are not seeds (the swarm leechers we're talking to).
    /// Derived from the connected-peer and seed counts the session reports.
    public var leecherCount: Int {
        max(0, connectionCount - (seedCount ?? 0))
    }

    /// Progress toward the per-task seed-ratio target, 0…1, or nil when no target
    /// is set. Lets the UI show a "seeding to 2.0 · 65%" countdown.
    public var seedRatioProgress: Double? {
        guard let limit = seedRatioLimit, limit > 0 else { return nil }
        return min(1, shareRatio / limit)
    }

    /// Seconds remaining at the current speed, or nil if unknown/stalled.
    public var estimatedTimeRemaining: TimeInterval? {
        guard status == .downloading, downloadSpeed > 0, let total = totalBytes else { return nil }
        let remaining = Double(total - bytesDownloaded)
        guard remaining > 0 else { return 0 }
        return remaining / downloadSpeed
    }

    /// The full save path including the task name.
    public var savePath: String {
        (saveDirectory as NSString).appendingPathComponent(name)
    }

    public var wantedFiles: [TransferFile] {
        files.filter(\.isWanted)
    }

    // MARK: Path safety

    /// Whether ``savePath`` resolves to a location strictly inside
    /// ``saveDirectory``. A defense-in-depth guard the engines check before any
    /// filesystem write/delete, so a malformed name can never escape the download
    /// folder even if name sanitisation is bypassed upstream. The containment and
    /// filename invariants live in ``PathSafety``.
    public var isSavePathContained: Bool {
        PathSafety.isContained(savePath, within: saveDirectory)
    }

    /// The absolute path of the payload to open / play / stream. For a multi-file
    /// torrent that's the largest wanted file, resolved under the save directory.
    /// The engine-declared per-file `path` is untrusted — a hostile `.torrent`
    /// could (against a buggy or downgraded libtorrent) carry a traversing path —
    /// so the joined result is verified to stay inside the save directory and
    /// falls back to ``savePath`` if it would escape. Callers that open/stream a
    /// torrent's file must route through here rather than joining `path` raw.
    public var primaryFilePath: String {
        guard isMultiFile,
              let largest = files.filter(\.isWanted).max(by: { $0.length < $1.length })
        else { return savePath }
        let candidate = (saveDirectory as NSString).appendingPathComponent(largest.path)
        return PathSafety.isContained(candidate, within: saveDirectory) ? candidate : savePath
    }
}
