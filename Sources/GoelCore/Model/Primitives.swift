import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux
#endif

/// Which engine backs a task. The UI never branches on this; the scheduler may.
public enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case http
    case torrent
    case hls
    case ftp
    case sftp
}

/// Per-file selection / priority within a multi-file transfer.
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

/// A concrete, persistable failure reason. Survives relaunch and drives the UI.
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
    /// Best-effort mapping of an arbitrary transfer error to a `DownloadError`:
    /// pass an existing `DownloadError` through unchanged, translate the common
    /// `URLError` codes, and otherwise fall back to `.network` with the
    /// underlying description. Shared by the HTTP and HLS engines.
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

/// Persistable status with distinct pre-metadata and seeding states.
public enum DownloadStatus: Codable, Sendable, Equatable, Hashable {
    case queued
    case requestingMetadata   // magnet: name/size unknown until peers respond
    case downloading
    case verifying            // payload downloaded; checking the integrity hash
    case paused
    case seeding              // torrent finished, still uploading
    case completed
    case failed(DownloadError)

    public var isActive: Bool {
        switch self {
        case .downloading, .verifying, .requestingMetadata, .seeding: return true
        default: return false
        }
    }

    /// Occupies a download slot (not seeding — seeding can run indefinitely).
    public var isDownloadingPhase: Bool {
        switch self {
        case .downloading, .verifying, .requestingMetadata: return true
        default: return false
        }
    }

    /// Counts as "work in flight" for queue-drain / power (queued + download phases).
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

    /// A finished payload — download bytes are all present (completed or seeding).
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

/// Where a task comes from. `kind` is derived from the source.
public enum DownloadSource: Codable, Sendable, Hashable {
    case url(URL)
    case magnet(String)
    case torrentFile(URL)
    case hlsStream(URL)

    public var kind: DownloadKind {
        switch self {
        case .url(let url):
            // `.url` covers every direct-download engine; the scheme decides
            // (reusing the case keeps every persisted blob decodable).
            switch url.scheme?.lowercased() ?? "" {
            case "ftp", "ftps": return .ftp
            case "sftp": return .sftp
            default: return .http
            }
        case .magnet, .torrentFile: return .torrent
        case .hlsStream: return .hls
        }
    }

    /// Whether this source may be auto-added from the browser-capture spool
    /// *without* a confirmation banner. The spool is a no-confirmation channel,
    /// so only credential-free web-download schemes qualify: a web page's link
    /// must never be able to make the app open an authenticated `sftp:`/`ftp:`
    /// connection (which would spend the user's ssh-agent identities or a stored
    /// Keychain secret against an attacker-chosen host). Those schemes are still
    /// accepted through the in-app add box, which is an explicit user action.
    public var isBrowserCaptureSafe: Bool {
        switch self {
        case .magnet, .torrentFile: return true
        case .url(let url), .hlsStream(let url):
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        }
    }

    /// Web-page / server-script path extensions that are pages to *view*, not
    /// files to download. Used to gate the passive clipboard-capture banner so a
    /// copied article/repo/search URL isn't offered as a download.
    public static let nonDownloadPageExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "php", "php3", "php4", "php5", "phtml",
        "asp", "aspx", "jsp", "jspx", "cfm", "cgi", "pl", "do", "action",
    ]

    /// A conservative heuristic for the *automatic* clipboard suggestion: does
    /// this source look like a downloadable file rather than a web page the user
    /// merely copied? Gates ONLY the passive clipboard banner — the explicit Add
    /// box and the browser-extension capture still accept any allowed URL, so the
    /// user can always download an edge-case URL by hand.
    ///
    /// Non-HTTP sources (magnet/torrent/HLS/FTP/SFTP) are always file transfers,
    /// so they pass. An HTTP(S) URL passes only when its path ends in a concrete
    /// file extension that isn't a known page/markup type — an extensionless URL
    /// (`…/user/repo`, a bare domain, a dynamic endpoint) reads as a page and is
    /// skipped.
    public var looksLikeDownloadableFile: Bool {
        switch self {
        case .magnet, .torrentFile, .hlsStream:
            return true
        case .url(let url):
            let scheme = url.scheme?.lowercased()
            if scheme == "ftp" || scheme == "ftps" || scheme == "sftp" { return true }
            // http/https: require a file-ish extension that isn't a web page.
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            return !Self.nonDownloadPageExtensions.contains(ext)
        }
    }

    /// A canonical string used for display and copy — the full, original source
    /// (for a magnet, the complete link including its `dn=`/`tr=` parameters).
    public var locator: String {
        switch self {
        case .url(let u): return u.absoluteString
        case .magnet(let m): return m
        case .torrentFile(let u): return u.absoluteString
        case .hlsStream(let u): return u.absoluteString
        }
    }

    /// The canonical identity used for duplicate detection. For a magnet this is
    /// the `btih:` infohash (lowercased): two magnet links for the *same* torrent
    /// routinely differ only in their `dn=` display name or `tr=` tracker list, so
    /// keying on the raw string would let the identical torrent be added twice and
    /// collide on the same save path. Non-magnets — and a malformed magnet with no
    /// infohash — fall back to ``locator``.
    public var dedupKey: String {
        guard case .magnet(let m) = self else { return locator }
        if let range = m.range(of: #"btih:([a-zA-Z0-9]+)"#, options: .regularExpression) {
            return String(m[range])
                .replacingOccurrences(of: "btih:", with: "")
                .lowercased()
        }
        return m
    }

    /// Parse a raw, user-entered line into a source, enforcing a scheme allowlist.
    ///
    /// Accepts `magnet:` links, `*.torrent` URLs, HTTP(S) URLs, FTP(S) URLs,
    /// and `sftp://` URLs (with a host) only. Anything else — `file:`,
    /// `javascript:`, schemeless junk — is
    /// rejected (returns `nil`). This is the single front door for adding
    /// downloads, so the allowlist is enforced in one place (defends against
    /// SSRF / local-file reads).
    public static func parse(_ line: String) -> DownloadSource? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("magnet:") { return .magnet(trimmed) }
        // The scheme check must run BEFORE the `.torrent`-suffix routing —
        // otherwise `file:///…/x.torrent` (local-file read) or any other
        // scheme URLSession accepts would slip past the allowlist via the
        // suffix. Local `.torrent` files enter through the watch-folder /
        // file-open paths, which construct `.torrentFile` directly from a
        // user-action file URL and never go through `parse`.
        if let url = URL(string: trimmed),
           url.pathExtension.lowercased() == "torrent",
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // `pathExtension` ignores any `?query`, so tokenised tracker URLs
            // (e.g. `…/movie.torrent?token=abc`) still route to the torrent engine.
            return .torrentFile(url)
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                // An `.m3u8` URL is an HLS stream playlist, routed to the HLS engine.
                // `pathExtension` ignores any `?query` so tokenised CDN URLs still match.
                if url.pathExtension.lowercased() == "m3u8" { return .hlsStream(url) }
                return .url(url)
            }
            if scheme == "ftp" || scheme == "ftps" {
                // Needs a host to be a real target (ftp://host/path); a bare
                // `ftp:` or hostless form is junk that can only fail at connect.
                guard url.host?.isEmpty == false else { return nil }
                // Never persist an inline password (`ftp://user:pass@host`). Like
                // the SFTP case below, a URL is stored/displayed/exported/copied
                // verbatim, so an inline secret would leak into the task DB, JSON
                // backups, the plain-text "Export list", and the clipboard. Strip
                // it; FTP auth is resolved from the Keychain credential store at
                // connect time (see `FTPEngine.credentials(for:)`).
                if url.password != nil,
                   var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.password = nil
                    if let stripped = comps.url { return .url(stripped) }
                }
                return .url(url)   // kind derives .ftp from the scheme
            }
            if scheme == "sftp" {
                // Needs a host to be a real target (sftp://host/path); a bare
                // `sftp:` or hostless form is junk.
                guard url.host?.isEmpty == false else { return nil }
                // Never persist an inline password (`sftp://user:pass@host`).
                // SFTP secrets live in the Keychain and are resolved at connect
                // time; strip any inline secret so it can't leak into the task
                // DB, exports, or the copyable on-screen "Source" field.
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
    /// Human-readable byte size, e.g. "5.27 GB".
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
    /// Human-readable transfer speed, e.g. "14.2 MB/s".
    var speedString: String {
        guard self > 0 else { return "—" }
        return Int64(self).byteString + "/s"
    }
}
