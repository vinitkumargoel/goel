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

    /// Localised at read time: the case (not the text) is what's persisted, so a language
    /// switch re-renders old failures too.
    public var message: String {
        switch self {
        case .network(let m): return L10n.t("Network error: %@", m)
        case .httpStatus(let code): return L10n.t("Server returned HTTP %ld", code)
        case .diskFull(let needed, let available):
            return L10n.t("Not enough disk space (need %@, have %@)",
                          needed.byteString, available.byteString)
        case .checksumMismatch: return L10n.t("Checksum mismatch — the file did not match its published hash")
        case .rangeNotSupported: return L10n.t("Server does not support resuming (no range support)")
        case .remoteFileChanged: return L10n.t("The remote file changed since the download started")
        case .fileMissing: return L10n.t("The local file is missing")
        case .canceled: return L10n.t("Canceled")
        case .timedOut: return L10n.t("Connection timed out")
        case .unknown(let m): return m.isEmpty ? L10n.t("Unknown error") : m
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

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
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
            return .torrentFile(strippingUserInfo(url))
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                // `https://user:pass@host/…` would be stored, exported and served by the portal
                // verbatim; ``parseWithCredentials(_:)`` hands the secret back as a header instead.
                let url = strippingUserInfo(url)
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

    /// Like ``parse(_:)``, but an http(s) URL's inline `user:pass@` comes back as a Basic
    /// `Authorization` value so a caller that can attach per-task headers keeps the download working.
    public static func parseWithCredentials(_ line: String)
        -> (source: DownloadSource, authorization: String?)? {
        guard let source = parse(line) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = comps.user, !user.isEmpty else { return (source, nil) }
        let pair = "\(user):\(comps.password ?? "")"
        return (source, "Basic " + Data(pair.utf8).base64EncodedString())
    }

    static func strippingUserInfo(_ url: URL) -> URL {
        guard url.user != nil || url.password != nil,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.user = nil
        comps.password = nil
        return comps.url ?? url
    }

    /// Query keys whose value is a bearer secret (presigned S3/GCS/Azure links, API tokens).
    static let secretQueryKeys: Set<String> = [
        "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "x-goog-signature", "x-goog-credential", "sig", "signature", "token",
        "access_token", "auth", "apikey", "api_key", "key", "password",
    ]

    /// What leaves the process (portal API, SSE, exports): no userinfo, and no query at all
    /// when any parameter is a signature/token — the rest of a presigned query identifies it too.
    public var redactedLocator: String { Self.redacted(locator) }

    public static func redacted(_ locator: String) -> String {
        guard var comps = URLComponents(string: locator),
              let scheme = comps.scheme?.lowercased(), scheme != "magnet" else { return locator }
        comps.user = nil
        comps.password = nil
        if let items = comps.queryItems,
           items.contains(where: { secretQueryKeys.contains($0.name.lowercased()) }) {
            comps.query = nil
        }
        return comps.string ?? locator
    }
}

public extension Int64 {
    /// Localised and decimal like Finder, via ``GoelFormat``; "—" for an unknown/empty size.
    var byteString: String {
        guard self > 0 else { return "—" }
        return GoelFormat.bytes(self)
    }
}

public extension Double {
    var speedString: String { GoelFormat.rate(self) }
}
