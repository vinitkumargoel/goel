import Foundation
#if canImport(os)
import os
#endif
// `fputs`/`stderr` for the non-Apple sink. Foundation no longer re-exports the
// platform C library on Linux, so the module is imported explicitly.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// GoelLog — single logging front door. "No telemetry" guarantee: local unified log on Apple, stderr on Linux,
// never a socket. Messages must be `StaticString` + ``GoelLogField``, so tokens/paths cannot be interpolated in.

/// Severity, ordered. Mirrors `OSLogType` on Apple platforms and drives the
/// stderr sink's floor everywhere else.
public enum GoelLogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug  = 0   // loop-level detail; off unless someone asks for it
    case info   = 1   // ordinary progress, kept only in the memory buffer
    case notice = 2   // durable milestones (task started/finished, server up)
    case error  = 3   // something failed but the app carried on
    case fault  = 4   // an invariant broke; the code has a bug

    public static func < (lhs: GoelLogLevel, rhs: GoelLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Fixed-width tag used by the stderr sink so columns line up.
    public var label: String {
        switch self {
        case .debug:  return "DEBUG "
        case .info:   return "INFO  "
        case .notice: return "NOTICE"
        case .error:  return "ERROR "
        case .fault:  return "FAULT "
        }
    }

    /// Parses the `GOEL_LOG_LEVEL` environment value. Unknown text returns nil
    /// so the caller can fall back rather than silently muting the log.
    static func named(_ raw: String) -> GoelLogLevel? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "debug":            return .debug
        case "info":             return .info
        case "notice", "default": return .notice
        case "error":            return .error
        case "fault", "critical": return .fault
        default:                 return nil
        }
    }

    #if canImport(os)
    var osType: OSLogType {
        switch self {
        case .debug:  return .debug
        case .info:   return .info
        case .notice: return .default
        case .error:  return .error
        case .fault:  return .fault
        }
    }
    #endif
}

/// One labelled log value carrying its privacy class: `.private` = who the user is / what they do (URLs, paths,
/// hosts, names); `.public` = machine behaviour (bytes, speeds, codes). Prefer the named constructors below.
public struct GoelLogField: Sendable, Equatable {
    public let label: String
    public let value: String
    public let isPrivate: Bool

    public init(label: String, value: String, isPrivate: Bool) {
        self.label = label
        self.value = value
        self.isPrivate = isPrivate
    }
}

// MARK: - Private-by-construction fields

public extension GoelLogField {

    /// A full URL — the single most identifying thing the app touches.
    static func url(_ url: URL, label: String = "url") -> GoelLogField {
        GoelLogField(label: label, value: url.absoluteString, isPrivate: true)
    }

    /// A URL that only exists as text (a magnet link, a raw locator).
    static func locator(_ locator: String, label: String = "locator") -> GoelLogField {
        GoelLogField(label: label, value: locator, isPrivate: true)
    }

    /// A file or folder path. Private even when it looks boring — the home
    /// directory alone carries the account's short name.
    static func path(_ path: String, label: String = "path") -> GoelLogField {
        GoelLogField(label: label, value: path, isPrivate: true)
    }

    /// A remote host (or host:port). Private: it says who the user talks to.
    static func host(_ host: String, label: String = "host") -> GoelLogField {
        GoelLogField(label: label, value: host, isPrivate: true)
    }

    /// An account name. Never log the matching secret at all — not even privately.
    static func user(_ user: String, label: String = "user") -> GoelLogField {
        GoelLogField(label: label, value: user, isPrivate: true)
    }

    /// A user-visible task or file name (torrent titles leak content interests).
    static func name(_ name: String, label: String = "name") -> GoelLogField {
        GoelLogField(label: label, value: name, isPrivate: true)
    }

    /// Free text of unknown provenance — a server message, a tool's stderr.
    /// Treated as private because remote text can echo back a query string.
    static func detail(_ text: String, label: String = "detail") -> GoelLogField {
        GoelLogField(label: label, value: text, isPrivate: true)
    }
}

// MARK: - Public-by-construction fields

public extension GoelLogField {

    /// A byte count. Volume is behaviour, not identity.
    static func bytes(_ count: Int64, label: String = "bytes") -> GoelLogField {
        GoelLogField(label: label, value: String(count), isPrivate: false)
    }

    /// A plain integer measurement (segments, peers, attempts, queue depth).
    static func count(_ count: Int, label: String) -> GoelLogField {
        GoelLogField(label: label, value: String(count), isPrivate: false)
    }

    /// A duration in seconds, rendered to milliseconds.
    static func duration(_ seconds: Double, label: String = "seconds") -> GoelLogField {
        GoelLogField(label: label, value: String(format: "%.3f", seconds), isPrivate: false)
    }

    /// Bytes per second.
    static func speed(_ bytesPerSecond: Double, label: String = "bytesPerSec") -> GoelLogField {
        GoelLogField(label: label, value: String(format: "%.0f", bytesPerSecond), isPrivate: false)
    }

    /// A state/enum token — a `DownloadStatus` case name, an engine phase.
    static func state(_ state: String, label: String = "state") -> GoelLogField {
        GoelLogField(label: label, value: state, isPrivate: false)
    }

    /// A numeric error/status code (HTTP status, libcurl code, errno).
    static func code(_ code: Int, label: String = "code") -> GoelLogField {
        GoelLogField(label: label, value: String(code), isPrivate: false)
    }

    /// A boolean flag.
    static func flag(_ value: Bool, label: String) -> GoelLogField {
        GoelLogField(label: label, value: value ? "true" : "false", isPrivate: false)
    }

    /// The *case name* of a failure — never its message, which routinely embeds the URL that failed.
    /// Pair with ``detail(_:label:)`` when the message itself is needed.
    static func errorKind(_ error: DownloadError, label: String = "error") -> GoelLogField {
        GoelLogField(label: label, value: DiagnosticsErrorLabel.of(error), isPrivate: false)
    }

    /// Which engine a line came from.
    static func kind(_ kind: DownloadKind, label: String = "kind") -> GoelLogField {
        GoelLogField(label: label, value: kind.rawValue, isPrivate: false)
    }
}

// MARK: - Namespace

/// Subsystem/category namespace and the shared per-area loggers. Categories mirror the real architecture so
/// `log stream --predicate 'subsystem == "com.goel.downloader" && category == "engine.torrent"'` isolates one component.
public enum GoelLog {

    /// The unified-log subsystem. Falls back to the shipping bundle id when there is no bundle (SwiftPM
    /// tests, the Linux daemon) so filtering predicates work identically in every context.
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.goel.downloader"

    /// One category per architectural area. Raw values are the strings used in log predicates and must stay
    /// stable — effectively public API for anyone debugging a user's install over email.
    public enum Category: String, Sendable, CaseIterable {
        case engineHTTP    = "engine.http"
        case engineTorrent = "engine.torrent"
        case engineSFTP    = "engine.sftp"
        case engineFTP     = "engine.ftp"
        case engineHLS     = "engine.hls"
        case scheduler     = "scheduler"
        case persistence   = "persistence"
        case remote        = "remote"
        case app           = "app"
    }

    public static let engineHTTP    = GoelLogger(category: .engineHTTP)
    public static let engineTorrent = GoelLogger(category: .engineTorrent)
    public static let engineSFTP    = GoelLogger(category: .engineSFTP)
    public static let engineFTP     = GoelLogger(category: .engineFTP)
    public static let engineHLS     = GoelLogger(category: .engineHLS)
    public static let scheduler     = GoelLogger(category: .scheduler)
    public static let persistence   = GoelLogger(category: .persistence)
    public static let remote        = GoelLogger(category: .remote)
    public static let app           = GoelLogger(category: .app)

    /// The logger for a given engine, so engine-generic code can still land in
    /// the right category.
    public static func engine(_ kind: DownloadKind) -> GoelLogger {
        switch kind {
        case .http:    return engineHTTP
        case .torrent: return engineTorrent
        case .sftp:    return engineSFTP
        case .ftp:     return engineFTP
        case .hls:     return engineHLS
        }
    }

    // MARK: Fallback-sink configuration

    /// Non-Apple (stderr) sink config only. Apple's unified log filters/redacts itself (`log config --subsystem
    /// com.goel.downloader --mode level:debug,private_data:on`); a second floor here would defeat that tooling.
    enum Fallback {
        /// Lines below this level are dropped by the stderr sink. Defaults to
        /// `.notice` so a daemon's console stays readable.
        static let minimumLevel: GoelLogLevel = {
            guard let raw = ProcessInfo.processInfo.environment["GOEL_LOG_LEVEL"],
                  let level = GoelLogLevel.named(raw) else { return .notice }
            return level
        }()

        /// Whether the stderr sink prints private values verbatim. Off unless the operator opts in: stderr
        /// usually lands in a journal/log file that outlives the process, so no user URLs there by default.
        static let revealsPrivateValues: Bool = {
            let raw = ProcessInfo.processInfo.environment["GOEL_LOG_PRIVATE"]?.lowercased()
            return raw == "1" || raw == "true" || raw == "yes"
        }()
    }

    /// Placeholder substituted for a private value that is not being revealed.
    /// Matches the unified log's own wording so the two sinks read alike.
    static let privatePlaceholder = "<private>"

    /// Splits fields into the public and private halves of a line. `os.Logger` applies privacy per
    /// interpolation segment, so one `.public` + one `.private` blob is the only exact redaction boundary.
    static func split(_ fields: [GoelLogField]) -> (publicText: String, privateText: String) {
        var publicParts: [String] = []
        var privateParts: [String] = []
        for field in fields {
            let rendered = "\(field.label)=\(field.value)"
            if field.isPrivate { privateParts.append(rendered) } else { publicParts.append(rendered) }
        }
        return (publicParts.joined(separator: " "), privateParts.joined(separator: " "))
    }

    /// Renders a complete line for the stderr sink. Pure and side-effect free so
    /// the redaction contract can be unit-tested without touching a real sink.
    static func renderLine(
        level: GoelLogLevel,
        category: Category,
        message: String,
        fields: [GoelLogField],
        revealPrivate: Bool,
        timestamp: Date = Date()
    ) -> String {
        let (publicText, privateText) = split(fields)
        var line = "\(Self.timestampFormatter.string(from: timestamp)) \(level.label) [\(category.rawValue)] \(message)"
        if !publicText.isEmpty { line += " \(publicText)" }
        if !privateText.isEmpty {
            line += " | \(revealPrivate ? privateText : privatePlaceholder)"
        }
        return line
    }

    /// ISO-8601 in UTC: unambiguous when a user pastes a console excerpt into an
    /// email from another timezone.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Logger

/// A per-category logging handle. Cheap to copy and safe to share; the Apple implementation holds
/// one `os.Logger` for the process lifetime rather than rebuilding an `os_log_t` per call.
public struct GoelLogger: @unchecked Sendable {

    public let category: GoelLog.Category

    #if canImport(os)
    private let osLogger: os.Logger
    #endif

    public init(category: GoelLog.Category) {
        self.category = category
        #if canImport(os)
        self.osLogger = os.Logger(subsystem: GoelLog.subsystem, category: category.rawValue)
        #endif
    }

    // MARK: Level shorthands

    /// Loop-level detail. Compiled in but suppressed by default on both sinks.
    public func debug(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.debug, message, fields)
    }

    /// Ordinary progress.
    public func info(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.info, message, fields)
    }

    /// A durable milestone worth finding after the fact.
    public func notice(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.notice, message, fields)
    }

    /// Something failed; the app recovered or surfaced it to the user.
    public func error(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.error, message, fields)
    }

    /// An invariant broke — this is a bug in our code, not the network's.
    public func fault(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.fault, message, fields)
    }

    /// Array-taking form for call sites that build fields conditionally.
    public func log(_ level: GoelLogLevel, _ message: StaticString, fields: [GoelLogField]) {
        emit(level, message, fields)
    }

    // MARK: Sinks

    private func emit(_ level: GoelLogLevel, _ message: StaticString, _ fields: [GoelLogField]) {
        #if canImport(os)
        let (publicText, privateText) = GoelLog.split(fields)
        // Three shapes rather than one so an empty half does not print a stray
        // separator (or a bare `<private>`) in Console.app.
        if privateText.isEmpty && publicText.isEmpty {
            osLogger.log(level: level.osType, "\(message, privacy: .public)")
        } else if privateText.isEmpty {
            osLogger.log(level: level.osType, "\(message, privacy: .public) \(publicText, privacy: .public)")
        } else if publicText.isEmpty {
            osLogger.log(level: level.osType, "\(message, privacy: .public) | \(privateText, privacy: .private)")
        } else {
            osLogger.log(level: level.osType,
                         "\(message, privacy: .public) \(publicText, privacy: .public) | \(privateText, privacy: .private)")
        }
        #else
        guard level >= GoelLog.Fallback.minimumLevel else { return }
        let line = GoelLog.renderLine(
            level: level,
            category: category,
            message: "\(message)",
            fields: fields,
            revealPrivate: GoelLog.Fallback.revealsPrivateValues
        )
        // `fputs` on the unbuffered stderr stream keeps concurrent lines from
        // interleaving mid-line without needing a lock of our own.
        fputs(line + "\n", stderr)
        #endif
    }
}

// MARK: - Shared error labelling

/// Maps a ``DownloadError`` to a stable, **non-identifying** token for the logger and ``DiagnosticsBundle``.
/// `DownloadError.message` embeds server text and often the failing URL, so only the case name (+ HTTP status) survives.
enum DiagnosticsErrorLabel {
    static func of(_ error: DownloadError) -> String {
        switch error {
        case .network:           return "network"
        case .httpStatus(let c): return "http-\(c)"
        case .diskFull:          return "diskFull"
        case .checksumMismatch:  return "checksumMismatch"
        case .rangeNotSupported: return "rangeNotSupported"
        case .remoteFileChanged: return "remoteFileChanged"
        case .fileMissing:       return "fileMissing"
        case .canceled:          return "canceled"
        case .timedOut:          return "timedOut"
        case .unknown:           return "unknown"
        }
    }
}
