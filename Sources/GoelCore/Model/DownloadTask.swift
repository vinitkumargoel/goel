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
        mirrors: [String]? = nil
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

    /// Reduce a raw, possibly hostile name down to a single safe filename
    /// component. Strips any directory parts (defeating `../` traversal and
    /// absolute paths) and rejects empty, `.`/`..`, hidden, and slash-bearing
    /// names, falling back to `fallback`.
    public static func sanitizedName(_ raw: String, fallback: String = "download") -> String {
        let last = (raw as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty || last == "." || last == ".." || last.hasPrefix(".") || last.contains("/") {
            return fallback
        }
        return clampLength(last)
    }

    /// Clamp a filename to a filesystem-safe byte length. macOS's `NAME_MAX` is
    /// 255 UTF-8 bytes; a longer name fails the write outright
    /// (`NSFileWriteInvalidFileNameError` — "the file name … is invalid"), which
    /// is exactly what opaque, query-token CDN URLs (Google video-downloads,
    /// signed S3 links, …) produce when their last path component is hundreds of
    /// characters long. We clamp well under the hard limit to leave room for a
    /// conflict suffix like ` (12)`, and we preserve the extension so the file
    /// stays openable.
    public static func clampLength(_ name: String, maxBytes: Int = 240) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        // Reserve room for ".<ext>"; if the extension itself is absurdly long
        // (not a real extension), drop it and just clamp the whole string.
        let extBudget = (!ext.isEmpty && ext.utf8.count <= 16) ? ext.utf8.count + 1 : 0
        let stemBudget = max(1, maxBytes - extBudget)
        let clampedStem = truncateUTF8(stem, toBytes: stemBudget)
        return extBudget == 0 ? truncateUTF8(name, toBytes: maxBytes)
                              : clampedStem + "." + ext
    }

    /// Truncate a string to at most `max` UTF-8 bytes without splitting a
    /// multi-byte character.
    private static func truncateUTF8(_ s: String, toBytes max: Int) -> String {
        guard s.utf8.count > max else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out.isEmpty ? String(s.prefix(1)) : out
    }

    /// Return `base` if no file with that name exists in `directory`, otherwise
    /// append ` (1)`, ` (2)`, … before the extension until the path is free
    /// (never-clobber). Bounded so a pathological directory can't spin forever.
    public static func uniqueName(base: String, in directory: String) -> String {
        let fm = FileManager.default
        let path = (directory as NSString).appendingPathComponent(base)
        guard fm.fileExists(atPath: path) else { return base }
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for n in 1...9_999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidatePath = (directory as NSString).appendingPathComponent(candidate)
            if !fm.fileExists(atPath: candidatePath) { return candidate }
        }
        return base
    }

    /// Whether ``savePath`` resolves to a location strictly inside
    /// ``saveDirectory``. A defense-in-depth guard the engines check before any
    /// filesystem write/preallocate/delete, so a malformed name can never escape
    /// the download folder even if name sanitisation is bypassed upstream.
    public var isSavePathContained: Bool {
        // Resolve symlinks (not just `..`/`~`): a symlinked save directory — or a
        // symlink component in the path — must not let the resolved file escape the
        // resolved download folder. `standardizingPath` alone leaves symlinks intact.
        let dir = (saveDirectory as NSString).resolvingSymlinksInPath
        let full = (savePath as NSString).resolvingSymlinksInPath
        return full == dir || full.hasPrefix(dir + "/")
    }
}
