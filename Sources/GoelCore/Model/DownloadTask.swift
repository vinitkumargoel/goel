import Foundation

public struct DownloadTask: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var source: DownloadSource
    public var name: String
    public var saveDirectory: String

    public var totalBytes: Int64?

    public var bytesDownloaded: Int64
    public var bytesUploaded: Int64
    public var downloadSpeed: Double
    public var uploadSpeed: Double

    public var status: DownloadStatus
    public var priority: FilePriority
    public var files: [TransferFile]
    public var connectionCount: Int

    public var addedAt: Date
    public var completedAt: Date?

    public var resumeData: Data?

    public var expectedChecksum: Checksum?

    public var connections: [TaskConnection]?

    public var seedCount: Int?

    public var remoteInfo: RemoteInfo?

    public var scanVerdict: String?

    public var speedLimitBytesPerSec: Int64?

    public var sequentialDownload: Bool?

    public var scheduledAt: Date?

    public var mirrors: [String]?

    public var infoHash: String?

    public var trackers: [TorrentTracker]?

    public var pieceAvailability: [Double]?

    public var uploadLimitBytesPerSec: Int64?

    public var seedRatioLimit: Double?

    /// Legacy single category, kept so old persisted tasks still decode; ``tags`` supersedes it.
    public var label: String?

    public var tags: [String]?

    public var note: String?

    /// Only ever sent to the same origin as the download URL.
    public var referer: String?

    public var requestHeaders: [String: String]?

    /// A bearer credential: never persisted, hence its absence from ``CodingKeys``.
    public var cookieHeader: String?

    public var cookieSource: CookieSource?

    /// Cookies go to exactly this host, never a mirror — that hands the user's session to its operator.
    public var cookieHost: String?

    public var retryAttempt: Int?

    /// Applied once when metadata resolves then dropped, so a re-enabled file is never re-skipped.
    public var initialSkipFileIDs: [Int]?

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

    /// Listed by hand so ``cookieHeader`` stays absent and can never be encoded; add every new property.
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

    public var kind: DownloadKind { source.kind }

    public var hasMetadata: Bool { totalBytes != nil }

    public var isMultiFile: Bool { files.count > 1 }

    public var fractionCompleted: Double {
        if status.hasData { return 1 }
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(total))
    }

    public var shareRatio: Double {
        guard bytesDownloaded > 0 else { return 0 }
        return Double(bytesUploaded) / Double(bytesDownloaded)
    }

    public var leecherCount: Int {
        max(0, connectionCount - (seedCount ?? 0))
    }

    public var seedRatioProgress: Double? {
        guard let limit = seedRatioLimit, limit > 0 else { return nil }
        return min(1, shareRatio / limit)
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard status == .downloading, downloadSpeed > 0, let total = totalBytes else { return nil }
        let remaining = Double(total - bytesDownloaded)
        guard remaining > 0 else { return 0 }
        return remaining / downloadSpeed
    }

    public var savePath: String {
        (saveDirectory as NSString).appendingPathComponent(name)
    }

    public var wantedFiles: [TransferFile] {
        files.filter(\.isWanted)
    }

    public var sourceHost: String? {
        switch source {
        case .url(let url), .hlsStream(let url): return url.host?.lowercased()
        case .magnet, .torrentFile: return nil
        }
    }

    /// Host-exact, never a suffix match: `files.example.com` ≠ `cdn.example.com`, and a leak is takeover.
    public func sendsCookies(to url: URL) -> Bool {
        guard let cookieHeader, !cookieHeader.isEmpty else { return false }
        return CookieHeader.matches(cookieHost: cookieHost ?? sourceHost, url: url)
    }

    /// The single place cookies enter the request path — attach them nowhere else or the host check is lost.
    public func outboundHeaders(for url: URL) -> [String: String] {
        var headers = requestHeaders ?? [:]
        guard let cookieHeader, sendsCookies(to: url) else { return headers }
        headers = headers.filter { $0.key.lowercased() != "cookie" }
        headers["Cookie"] = cookieHeader
        return headers
    }

    /// Engines must check this before any write/delete, in case name sanitisation was bypassed upstream.
    public var isSavePathContained: Bool {
        PathSafety.isContained(savePath, within: saveDirectory)
    }

    /// The engine-declared per-file `path` is untrusted, so anything escaping `saveDirectory` is refused.
    public var primaryFilePath: String {
        guard isMultiFile,
              let largest = files.filter(\.isWanted).max(by: { $0.length < $1.length })
        else { return savePath }
        let candidate = (saveDirectory as NSString).appendingPathComponent(largest.path)
        return PathSafety.isContained(candidate, within: saveDirectory) ? candidate : savePath
    }
}

public enum CookieSource: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case none
    case browser
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none:    return "None"
        case .browser: return "From browser"
        case .manual:  return "Paste manually"
        }
    }

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

/// These values are credentials: anything that could split a request or blow the header budget is dropped.
public enum CookieHeader {

    public static let maxPairs = 128

    /// 8 KiB because most servers reject a larger header block outright.
    public static let maxLength = 8192

    /// Duplicate names collapse to the **last** value but keep the first's position.
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

    /// The only function that may produce a `Cookie` value stored on a task — every entry point uses it.
    public static func sanitized(_ raw: String) -> String? {
        var kept: [String] = []
        var length = 0
        for pair in pairs(in: raw) {
            let rendered = "\(pair.name)=\(pair.value)"
            let addition = rendered.utf8.count + (kept.isEmpty ? 0 : 2)
            guard length + addition <= maxLength else { break }
            kept.append(rendered)
            length += addition
        }
        return kept.isEmpty ? nil : kept.joined(separator: "; ")
    }

    public static func count(in raw: String) -> Int { pairs(in: raw).count }

    /// Names only — names are safe to show, values are credentials.
    public static func names(in raw: String) -> [String] { pairs(in: raw).map(\.name) }

    public static func scope(for url: URL) -> String? { url.host?.lowercased() }

    /// Host-exact on purpose: a suffix match would send the session to any sibling host.
    public static func matches(cookieHost: String?, url: URL) -> Bool {
        guard let cookieHost, let host = url.host?.lowercased() else { return false }
        let scope = cookieHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !scope.isEmpty && scope == host
    }

    /// RFC 7230 `tchar` only: excluding `=`, `;`, whitespace and controls stops a name ending its own pair.
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

    /// Printable ASCII, no `;`: rejecting CR/LF/NUL is what blocks header splitting.
    private static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != ";" }
    }
}
