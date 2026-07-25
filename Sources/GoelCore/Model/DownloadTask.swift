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

    /// The browser session's `Cookie` header value for this download
    /// (`"sid=abc; csrf=def"`), captured by the extension or pasted by the user.
    /// This is what makes a paywalled / logged-in / private-forum file downloadable
    /// at all: without it the server hands back a login page instead of the file.
    ///
    /// **Deliberately NOT persisted** — it is excluded from ``CodingKeys``, so it
    /// never reaches the SQLite store and never reaches ``DownloadManager``'s
    /// export envelope. Three reasons, in order of weight:
    ///
    /// 1. A session cookie is a *bearer credential*: whoever holds it is logged in
    ///    as the user, with no password and usually no second factor.
    /// 2. The task store is plaintext SQLite in Application Support, and the JSON
    ///    export (File ▸ Export) encodes tasks wholesale — a persisted cookie
    ///    would ride into any backup the user shared with someone else.
    /// 3. Cookies expire in hours-to-days anyway, so persisting them buys little:
    ///    a stale one fails exactly like no cookie at all, but with a worse error.
    ///
    /// The Keychain was the other candidate. It was rejected for the *value*
    /// because the engine needs the cookie on a background actor during a resume,
    /// and a Keychain read can block on a user prompt (see ``CredentialLookup``) —
    /// turning "resume" into a modal password dialog. What survives a relaunch is
    /// the non-secret provenance pair below (``cookieSource``/``cookieHost``), so
    /// the UI can say "re-import cookies from your browser" instead of silently
    /// failing with a 403.
    ///
    /// Never log this value, in any privacy class. See ``GoelLogField``.
    public var cookieHeader: String?

    /// Where ``cookieHeader`` came from. Persisted: it is provenance, not a
    /// secret, and it lets the UI explain an empty cookie jar after a relaunch.
    public var cookieSource: CookieSource?

    /// The host ``cookieHeader`` was captured for. Cookies are only ever sent to
    /// exactly this host (see ``sendsCookies(to:)``) — never to a mirror on
    /// another host, which would hand the user's session to the mirror operator.
    /// nil = fall back to the task's own source host.
    public var cookieHost: String?

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
        cookieHeader: String? = nil,
        cookieSource: CookieSource? = nil,
        cookieHost: String? = nil,
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
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.cookieHost = cookieHost
        self.retryAttempt = retryAttempt
        self.initialSkipFileIDs = initialSkipFileIDs
    }

    // MARK: Codable

    /// Spelled out rather than synthesised for exactly one reason: ``cookieHeader``
    /// is **absent** from this list, so the compiler guarantees the credential is
    /// never encoded — not into the SQLite blob, not into the JSON export, not
    /// into any future serialisation someone adds. `init(from:)` still synthesises
    /// because the omitted property has a default (`nil`), so a decoded task simply
    /// comes back cookie-less. Every other stored property must stay listed here or
    /// it silently stops persisting.
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
        case retryAttempt, initialSkipFileIDs
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

    /// Whether ``cookieHeader`` may ride on a request to `url`.
    ///
    /// Host-exact, never a suffix match. A cookie captured for `files.example.com`
    /// is not sent to `cdn.example.com`, because "same registrable domain" is not
    /// the same trust boundary — mirrors and CDNs are frequently third parties, and
    /// a leaked session cookie is a full account takeover. ``SegmentedTransfer``
    /// independently strips every custom header on a cross-host mirror request, so
    /// this is the first of two locks, not the only one.
    public func sendsCookies(to url: URL) -> Bool {
        guard let cookieHeader, !cookieHeader.isEmpty else { return false }
        // An explicit capture scope wins; otherwise cookies apply only to the
        // task's own origin (the manual-paste case, where the user pasted the
        // cookies *for this download*).
        return CookieHeader.matches(cookieHost: cookieHost ?? sourceHost, url: url)
    }

    /// Every custom header this task should send to `url`: the user's
    /// ``requestHeaders`` plus the captured `Cookie` when it is in scope.
    ///
    /// The single place cookies enter the request path — engines call this rather
    /// than reading ``requestHeaders`` directly, so the host check above cannot be
    /// forgotten at a call site. Any `Cookie` the user typed into the headers
    /// editor is replaced (not merged) by the captured one: two `Cookie` headers
    /// on one request is a protocol violation and servers pick unpredictably.
    public func outboundHeaders(for url: URL) -> [String: String] {
        var headers = requestHeaders ?? [:]
        guard let cookieHeader, sendsCookies(to: url) else { return headers }
        headers = headers.filter { $0.key.lowercased() != "cookie" }
        headers["Cookie"] = cookieHeader
        return headers
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

// MARK: - Browser cookies

/// Where a task's cookies came from.
///
/// Persisted with the task (it is provenance, not a secret). Its job is to make
/// the *absence* of a cookie explainable: after a relaunch the value is gone by
/// design, and "cookies came from your browser — re-import them" is a fixable
/// message, where a bare 403 is not.
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

/// Parsing, validation and normalisation of a `Cookie` request-header value.
///
/// Everything here is a pure function over a string so the whole cookie path can
/// be tested without a browser, a network, or a running engine. The values that
/// flow through are credentials, so the rules are conservative: anything that
/// could split a request, smuggle a second header, or blow a server's header
/// budget is dropped rather than escaped.
public enum CookieHeader {

    /// Most cookie pairs kept from one capture. Real sessions use a handful;
    /// hundreds means a tracking-cookie pile-up that would only bloat the request.
    public static let maxPairs = 128

    /// Longest normalised header value kept, in bytes. Most servers reject a
    /// request line/header block over 8 KiB with a 400 — sending more turns a
    /// working download into an unexplainable failure.
    public static let maxLength = 8192

    /// The pairs in a raw `Cookie` value, in order, invalid ones dropped.
    ///
    /// Duplicate names collapse to the **last** value seen (matching the header
    /// editor's `A: 1\nA: 2` → `2` rule) while keeping the position of the first
    /// occurrence, so the order the browser sent stays recognisable.
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

    /// A normalised, size-capped `Cookie` header value, or nil when nothing
    /// survivable is left. The one function that may produce a value stored on a
    /// ``DownloadTask`` — every entry point (extension capture, manual paste,
    /// scripting) must go through it.
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

    /// RFC 7230 `tchar` set — the characters a header/cookie *name* may use.
    /// Excluding everything else also excludes `=`, `;`, whitespace and every
    /// control character, so a name can never terminate its own pair.
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

    /// A cookie *value* may be empty (servers do issue `name=`), but must stay
    /// printable ASCII with no `;`. Rejecting CR/LF/NUL blocks header splitting;
    /// rejecting non-ASCII avoids `URLRequest` mangling a value we can't encode
    /// the way the browser did.
    private static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != ";" }
    }
}
