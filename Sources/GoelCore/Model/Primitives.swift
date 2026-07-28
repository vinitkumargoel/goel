import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux
#endif

public enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case http
    case torrent
    case hls
    case ftp
    case sftp
}

public enum FilePriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case skip = 0
    case low = 1
    case normal = 2
    case high = 3

    public static func < (lhs: FilePriority, rhs: FilePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .skip: return "Skip"
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

public enum DownloadError: Error, Codable, Sendable, Equatable, Hashable {
    case network(String)
    case httpStatus(Int)
    case diskFull(needed: Int64, available: Int64)
    case checksumMismatch
    case rangeNotSupported
    case remoteFileChanged
    case fileMissing
    case canceled
    case timedOut
    case unknown(String)

    public var message: String {
        switch self {
        case .network(let m): return "Network error: \(m)"
        case .httpStatus(let code): return "Server returned HTTP \(code)"
        case .diskFull(let needed, let available):
            return "Not enough disk space (need \(needed.byteString), have \(available.byteString))"
        case .checksumMismatch: return "Checksum mismatch — the file did not match its published hash"
        case .rangeNotSupported: return "Server does not support resuming (no range support)"
        case .remoteFileChanged: return "The remote file changed since the download started"
        case .fileMissing: return "The local file is missing"
        case .canceled: return "Canceled"
        case .timedOut: return "Connection timed out"
        case .unknown(let m): return m.isEmpty ? "Unknown error" : m
        }
    }
}

public extension DownloadError {
    init(mapping error: Error) {
        if let de = error as? DownloadError { self = de; return }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: self = .timedOut
            case .cancelled: self = .canceled
            case .fileDoesNotExist: self = .fileMissing
            default: self = .network(ue.localizedDescription)
            }
            return
        }
        self = .network((error as NSError).localizedDescription)
    }
}

public enum DownloadStatus: Codable, Sendable, Equatable, Hashable {
    case queued
    case requestingMetadata
    case downloading
    case verifying
    case paused
    case seeding
    case completed
    case failed(DownloadError)

    public var isActive: Bool {
        switch self {
        case .downloading, .verifying, .requestingMetadata, .seeding: return true
        default: return false
        }
    }

    public var isDownloadingPhase: Bool {
        switch self {
        case .downloading, .verifying, .requestingMetadata: return true
        default: return false
        }
    }

    public var isActiveWork: Bool {
        switch self {
        case .queued, .requestingMetadata, .downloading, .verifying: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }

    public var hasData: Bool {
        switch self {
        case .completed, .seeding: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .requestingMetadata: return "Requesting info"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .paused: return "Paused"
        case .seeding: return "Seeding"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

public enum DownloadSource: Codable, Sendable, Hashable {
    case url(URL)
    case magnet(String)
    case torrentFile(URL)
    case hlsStream(URL)

    public var kind: DownloadKind {
        switch self {
        case .url(let url):
            // Reusing `.url` for every direct-download scheme keeps persisted blobs decodable.
            switch url.scheme?.lowercased() ?? "" {
            case "ftp", "ftps": return .ftp
            case "sftp": return .sftp
            default: return .http
            }
        case .magnet, .torrentFile: return .torrent
        case .hlsStream: return .hls
        }
    }

    /// Credential-free schemes only: a web link must not spend ssh-agent/Keychain secrets via `sftp:`/`ftp:`.
    public var isBrowserCaptureSafe: Bool {
        switch self {
        case .magnet, .torrentFile: return true
        case .url(let url), .hlsStream(let url):
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        }
    }

    /// Every untrusted seam (`POST /api/add`, the extension spool) must SSRF-screen this.
    public var fetchTargetURL: URL? {
        switch self {
        case .url(let url), .torrentFile(let url), .hlsStream(let url): return url
        case .magnet: return nil
        }
    }

    public static let nonDownloadPageExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "php", "php3", "php4", "php5", "phtml",
        "asp", "aspx", "jsp", "jspx", "cfm", "cgi", "pl", "do", "action",
    ]

    /// A cosmetic heuristic for the clipboard banner ONLY — never a security gate.
    public var looksLikeDownloadableFile: Bool {
        switch self {
        case .magnet, .torrentFile, .hlsStream:
            return true
        case .url(let url):
            let scheme = url.scheme?.lowercased()
            if scheme == "ftp" || scheme == "ftps" || scheme == "sftp" { return true }
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            return !Self.nonDownloadPageExtensions.contains(ext)
        }
    }

    public var locator: String {
        switch self {
        case .url(let u): return u.absoluteString
        case .magnet(let m): return m
        case .torrentFile(let u): return u.absoluteString
        case .hlsStream(let u): return u.absoluteString
        }
    }

    /// Infohash, not the whole magnet: two links for one torrent differ only in `dn=`/`tr=` yet share a save path.
    public var dedupKey: String {
        guard case .magnet(let m) = self else { return locator }
        if let range = m.range(of: #"btih:([a-zA-Z0-9]+)"#, options: .regularExpression) {
            return String(m[range])
                .replacingOccurrences(of: "btih:", with: "")
                .lowercased()
        }
        return m
    }

    /// The one scheme allowlist — SSRF and local-file reads (`file:`, `javascript:`) must die here.
    public static func parse(_ line: String) -> DownloadSource? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("magnet:") { return .magnet(trimmed) }
        // Scheme check must precede `.torrent`-suffix routing, or `file:///…/x.torrent` slips the allowlist.
        if let url = URL(string: trimmed),
           url.pathExtension.lowercased() == "torrent",
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .torrentFile(url)
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                if url.pathExtension.lowercased() == "m3u8" { return .hlsStream(url) }
                return .url(url)
            }
            if scheme == "ftp" || scheme == "ftps" {
                guard url.host?.isEmpty == false else { return nil }
                // Never persist an inline password: URLs are stored, exported and copied verbatim.
                if url.password != nil,
                   var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.password = nil
                    if let stripped = comps.url { return .url(stripped) }
                }
                return .url(url)
            }
            if scheme == "sftp" {
                guard url.host?.isEmpty == false else { return nil }
                // Never persist an inline password: it would leak into the task DB, exports and the UI.
                if url.password != nil,
                   var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.password = nil
                    if let stripped = comps.url { return .url(stripped) }
                }
                return .url(url)
            }
        }
        return nil
    }
}

public extension Int64 {
    var byteString: String {
        let bytes = Double(self)
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        let exp = Swift.min(Int(log(bytes) / log(1024)), units.count - 1)
        let value = bytes / pow(1024, Double(exp))
        return String(format: exp == 0 ? "%.0f %@" : "%.2f %@", value, units[exp])
    }
}

public extension Double {
    var speedString: String {
        guard self > 0 else { return "—" }
        return Int64(self).byteString + "/s"
    }
}
