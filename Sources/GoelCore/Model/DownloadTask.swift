import Foundation

/// The unified task model both engines present upward: up/down bytes and speeds, a multi-file list, a
/// pre-metadata state (`totalBytes == nil`), a persistable status with a failure reason, and seeding.
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

    /// Integrity hash the finished file must match: verified before the task is marked complete, a
    /// mismatch fails it with ``DownloadError/checksumMismatch``. `nil` = no verification.
    public var expectedChecksum: Checksum?

    /// Live per-connection snapshots (HTTP segments / torrent peers) for the detail panel. Transient and
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

    /// On a paused task, the scheduler auto-starts it at (or shortly after) this time. Cleared the
    /// moment the task starts, manually or on schedule. Survives relaunch.
    public var scheduledAt: Date?

    /// Alternative URLs for the same file (HTTP only); segments spread across them and fail over. Every
    /// response is size-checked against the primary so a divergent mirror is dropped, not merged.
    public var mirrors: [String]?

    /// The torrent's v1 info-hash (hex), resolved from libtorrent so it is known
    /// for `.torrent` files too — not just magnet links. nil for non-torrents.
    public var infoHash: String?

    /// Live tracker status (torrents only), refreshed by the session. Transient —
    /// meaningless after relaunch. Optional so old persisted blobs still decode.
    public var trackers: [TorrentTracker]?

    /// Downsampled piece-availability map (torrents only): each value is the fraction 0…1 of that
    /// bucket's real pieces that are downloaded. Drives the Progress tab's piece grid. Transient.
    public var pieceAvailability: [Double]?

    /// Optional per-task upload cap in bytes/sec (torrents; 0 or nil = uncapped).
    public var uploadLimitBytesPerSec: Int64?

    /// Stop seeding once the share ratio reaches this value (torrents). nil = seed
    /// indefinitely (until the user stops it or a global rule applies).
    public var seedRatioLimit: Double?

    /// Free-form user category for grouping/filtering. Retained for back-compat; the multi-tag ``tags``
    /// supersedes it and the UI treats a legacy `label` as one more tag. nil = none.
    public var label: String?

    /// User-assigned tags for grouping/filtering (many per task). nil/empty = none.
    public var tags: [String]?

    /// A free-form note the user attaches to the download. nil = none.
    public var note: String?

    /// `Referer` header for this task's HTTP(S) request (some hosts gate downloads on it), from the
    /// extension or the user. Only ever sent to the same origin as the download URL. nil = none.
    public var referer: String?

    /// Extra request headers (name → value) for this task's HTTP(S) request. Reserved names
    /// (Host, Content-Length, …) are ignored by the engine. nil/empty = none.
    public var requestHeaders: [String: String]?

    /// Browser session `Cookie` value that makes a paywalled/logged-in file downloadable at all. **Never
    /// persisted** (absent from ``CodingKeys``): a bearer credential vs plaintext SQLite + JSON export.
    public var cookieHeader: String?

    /// Where ``cookieHeader`` came from. Persisted: it is provenance, not a
    /// secret, and it lets the UI explain an empty cookie jar after a relaunch.
    public var cookieSource: CookieSource?

    /// Host ``cookieHeader`` was captured for; cookies go to exactly this host (``sendsCookies(to:)``),
    /// never a mirror elsewhere — that hands the user's session to its operator. nil = the source host.
    public var cookieHost: String?

    /// Auto-retries in the current failure streak (see ``AppSettings/autoRetryEnabled``); reset to nil on
    /// success or a manual retry. Optional so old persisted blobs decode unchanged.
    public var retryAttempt: Int?

    /// Torrent file indices deselected on the add screen, before the per-file list exists. Applied once as
    /// `.skip` when metadata resolves, then dropped, so a re-enabled file is never re-skipped on resume.
    public var initialSkipFileIDs: [Int]?

    /// Which network interface(s) this download should egress through, overriding
    /// the server-wide aggregation policy. nil/`.auto` = follow the policy.
    public var networkSelection: NetworkSelection?

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
        cookieHeader: String? = nil,
        cookieSource: CookieSource? = nil,
        cookieHost: String? = nil,
        retryAttempt: Int? = nil,
        initialSkipFileIDs: [Int]? = nil,
        networkSelection: NetworkSelection? = nil
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
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.cookieHost = cookieHost
        self.retryAttempt = retryAttempt
        self.initialSkipFileIDs = initialSkipFileIDs
        self.networkSelection = networkSelection
    }

    // MARK: Codable

    /// Spelled out so ``cookieHeader`` is **absent**: the compiler then guarantees the credential is never
    /// encoded (SQLite or JSON export). Every other stored property must stay listed or stops persisting.
    private enum CodingKeys: String, CodingKey {
        case id, source, name, saveDirectory, totalBytes
        case bytesDownloaded, bytesUploaded, downloadSpeed, uploadSpeed
        case status, priority, files, connectionCount
        case addedAt, completedAt, resumeData, expectedChecksum
        case connections, seedCount, remoteInfo, scanVerdict
        case speedLimitBytesPerSec, sequentialDownload, scheduledAt
        case mirrors, infoHash, trackers, pieceAvailability
        case uploadLimitBytesPerSec, seedRatioLimit
        case label, tags, note, referer, requestHeaders
        case cookieSource, cookieHost           // provenance only — never the value
        case retryAttempt, initialSkipFileIDs, networkSelection
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

    // MARK: Cookies

    /// The host this task's own locator points at, lowercased. nil for magnets
    /// and `.torrent` files, which have no HTTP origin.
    public var sourceHost: String? {
        switch source {
        case .url(let url), .hlsStream(let url): return url.host?.lowercased()
        case .magnet, .torrentFile: return nil
        }
    }

    /// Whether ``cookieHeader`` may ride on a request to `url`. Host-exact, never a suffix match:
    /// `files.example.com` ≠ `cdn.example.com`, and a leaked session cookie is account takeover.
    public func sendsCookies(to url: URL) -> Bool {
        guard let cookieHeader, !cookieHeader.isEmpty else { return false }
        // An explicit capture scope wins; otherwise cookies apply only to the task's own origin
        // (the manual-paste case, where the user pasted the cookies *for this download*).
        return CookieHeader.matches(cookieHost: cookieHost ?? sourceHost, url: url)
    }

    /// ``requestHeaders`` plus the captured `Cookie` when in scope — the single place cookies enter the
    /// request path, so the host check can't be forgotten. A user-typed `Cookie` is replaced, not merged.
    public func outboundHeaders(for url: URL) -> [String: String] {
        var headers = requestHeaders ?? [:]
        guard let cookieHeader, sendsCookies(to: url) else { return headers }
        headers = headers.filter { $0.key.lowercased() != "cookie" }
        headers["Cookie"] = cookieHeader
        return headers
    }

    // MARK: Path safety

    /// Whether ``savePath`` stays strictly inside ``saveDirectory`` — defense-in-depth the engines check
    /// before any write/delete, in case name sanitisation was bypassed upstream. See ``PathSafety``.
    public var isSavePathContained: Bool {
        PathSafety.isContained(savePath, within: saveDirectory)
    }

    /// Absolute path to open/play/stream (multi-file torrent: the largest wanted file). The engine-declared
    /// per-file `path` is untrusted, so a joined result escaping `saveDirectory` falls back to ``savePath``.
    public var primaryFilePath: String {
        guard isMultiFile,
              let largest = files.filter(\.isWanted).max(by: { $0.length < $1.length })
        else { return savePath }
        let candidate = (saveDirectory as NSString).appendingPathComponent(largest.path)
        return PathSafety.isContained(candidate, within: saveDirectory) ? candidate : savePath
    }
}

// MARK: - Browser cookies

/// Where a task's cookies came from. Persisted (provenance, not a secret) so the *absence* of a cookie
/// after relaunch is explainable — "re-import them from your browser" is fixable, a bare 403 is not.
public enum CookieSource: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// No cookies — the request goes out anonymous. The default.
    case none
    /// Captured by the browser extension alongside the URL.
    case browser
    /// Pasted into the add sheet by the user.
    case manual

    public var id: String { rawValue }

    /// Short label for the picker.
    public var displayName: String {
        switch self {
        case .none:    return "None"
        case .browser: return "From browser"
        case .manual:  return "Paste manually"
        }
    }

    /// One line of plain language explaining what this choice does.
    public var explanation: String {
        switch self {
        case .none:
            return "Send the request signed out. Works for public files."
        case .browser:
            return "Use the login session the Goel° browser extension captured with this link."
        case .manual:
            return "Paste a Cookie header copied from your browser’s developer tools."
        }
    }
}

/// Pure-function parsing/validation/normalisation of a `Cookie` header value, testable without a browser.
/// The values are credentials: anything that could split a request or blow the header budget is dropped.
public enum CookieHeader {

    /// Most cookie pairs kept from one capture. Real sessions use a handful;
    /// hundreds means a tracking-cookie pile-up that would only bloat the request.
    public static let maxPairs = 128

    /// Longest normalised header value kept, in bytes. Most servers 400 a header block over 8 KiB,
    /// turning a working download into an unexplainable failure.
    public static let maxLength = 8192

    /// Pairs in a raw `Cookie` value, in order, invalid ones dropped. Duplicate names collapse to the
    /// **last** value (the header editor's `A: 1\nA: 2` → `2` rule) but keep the first's position.
    public static func pairs(in raw: String) -> [(name: String, value: String)] {
        var order: [String] = []
        var values: [String: String] = [:]
        for chunk in raw.split(separator: ";") {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = String(piece[piece.startIndex..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(piece[piece.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidName(name), isValidValue(value) else { continue }
            if values[name] == nil { order.append(name) }
            values[name] = value
        }
        return order.prefix(maxPairs).map { (name: $0, value: values[$0] ?? "") }
    }

    /// A normalised, size-capped `Cookie` value, or nil when nothing survives. The only function that may
    /// produce a value stored on a ``DownloadTask`` — every entry point must go through it.
    public static func sanitized(_ raw: String) -> String? {
        var kept: [String] = []
        var length = 0
        for pair in pairs(in: raw) {
            let rendered = "\(pair.name)=\(pair.value)"
            // +2 for the "; " separator that will join this one to the previous.
            let addition = rendered.utf8.count + (kept.isEmpty ? 0 : 2)
            guard length + addition <= maxLength else { break }
            kept.append(rendered)
            length += addition
        }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
    }

    /// How many cookies a raw value carries once cleaned. For UI copy
    /// ("4 cookies") — the count is safe to show, the values never are.
    public static func count(in raw: String) -> Int { pairs(in: raw).count }

    /// The cookie **names** only, for a UI that wants to show what is attached
    /// without revealing any secret. Names are not credentials; values are.
    public static func names(in raw: String) -> [String] { pairs(in: raw).map(\.name) }

    /// The capture scope for a download URL: its host, lowercased.
    public static func scope(for url: URL) -> String? { url.host?.lowercased() }

    /// Host-exact match between a stored capture scope and a request URL.
    /// See ``DownloadTask/sendsCookies(to:)`` for why this is not a suffix match.
    public static func matches(cookieHost: String?, url: URL) -> Bool {
        guard let cookieHost, let host = url.host?.lowercased() else { return false }
        let scope = cookieHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !scope.isEmpty && scope == host
    }

    // MARK: Token rules

    /// RFC 7230 `tchar` set for a header/cookie *name*. Excluding everything else also excludes `=`,
    /// `;`, whitespace and every control character, so a name can never terminate its own pair.
    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": return true
            case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".",
                 "^", "_", "`", "|", "~":         return true
            default:                              return false
            }
        }
    }

    /// A cookie *value* may be empty (`name=`) but must be printable ASCII with no `;`: rejecting
    /// CR/LF/NUL blocks header splitting, rejecting non-ASCII avoids `URLRequest` mangling it.
    private static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != ";" }
    }
}
