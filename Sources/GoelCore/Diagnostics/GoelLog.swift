import Foundation
#if canImport(os)
import os
#endif
// Foundation no longer re-exports the platform C library on Linux, so import it explicitly for `fputs`/`stderr`.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// No telemetry: local unified log on Apple, stderr on Linux, never a socket. `StaticString` messages keep tokens/paths uninterpolatable.

public enum GoelLogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug  = 0
    case info   = 1
    case notice = 2
    case error  = 3
    case fault  = 4

    public static func < (lhs: GoelLogLevel, rhs: GoelLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug:  return "DEBUG "
        case .info:   return "INFO  "
        case .notice: return "NOTICE"
        case .error:  return "ERROR "
        case .fault:  return "FAULT "
        }
    }

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

/// One labelled log value with its privacy class: `.private` = who the user is and what they do; `.public` = machine behaviour.
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

public extension GoelLogField {
    static func url(_ url: URL, label: String = "url") -> GoelLogField {
        GoelLogField(label: label, value: url.absoluteString, isPrivate: true)
    }

    static func locator(_ locator: String, label: String = "locator") -> GoelLogField {
        GoelLogField(label: label, value: locator, isPrivate: true)
    }

    static func path(_ path: String, label: String = "path") -> GoelLogField {
        GoelLogField(label: label, value: path, isPrivate: true)
    }

    static func host(_ host: String, label: String = "host") -> GoelLogField {
        GoelLogField(label: label, value: host, isPrivate: true)
    }

    /// An account name. Never log the matching secret — not even privately.
    static func user(_ user: String, label: String = "user") -> GoelLogField {
        GoelLogField(label: label, value: user, isPrivate: true)
    }

    static func name(_ name: String, label: String = "name") -> GoelLogField {
        GoelLogField(label: label, value: name, isPrivate: true)
    }

    /// Private: remote text of unknown provenance can echo back a query string.
    static func detail(_ text: String, label: String = "detail") -> GoelLogField {
        GoelLogField(label: label, value: text, isPrivate: true)
    }
}

public extension GoelLogField {
    static func bytes(_ count: Int64, label: String = "bytes") -> GoelLogField {
        GoelLogField(label: label, value: String(count), isPrivate: false)
    }

    static func count(_ count: Int, label: String) -> GoelLogField {
        GoelLogField(label: label, value: String(count), isPrivate: false)
    }

    static func duration(_ seconds: Double, label: String = "seconds") -> GoelLogField {
        GoelLogField(label: label, value: String(format: "%.3f", seconds), isPrivate: false)
    }

    static func speed(_ bytesPerSecond: Double, label: String = "bytesPerSec") -> GoelLogField {
        GoelLogField(label: label, value: String(format: "%.0f", bytesPerSecond), isPrivate: false)
    }

    static func state(_ state: String, label: String = "state") -> GoelLogField {
        GoelLogField(label: label, value: state, isPrivate: false)
    }

    static func code(_ code: Int, label: String = "code") -> GoelLogField {
        GoelLogField(label: label, value: String(code), isPrivate: false)
    }

    static func flag(_ value: Bool, label: String) -> GoelLogField {
        GoelLogField(label: label, value: value ? "true" : "false", isPrivate: false)
    }

    /// The failure's *case name* only — its message routinely embeds the URL that failed.
    static func errorKind(_ error: DownloadError, label: String = "error") -> GoelLogField {
        GoelLogField(label: label, value: DiagnosticsErrorLabel.of(error), isPrivate: false)
    }

    static func kind(_ kind: DownloadKind, label: String = "kind") -> GoelLogField {
        GoelLogField(label: label, value: kind.rawValue, isPrivate: false)
    }
}

public enum GoelLog {
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.goel.downloader"

    /// Raw values appear in log predicates and must stay stable — effectively public API for remote debugging.
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

    public static func engine(_ kind: DownloadKind) -> GoelLogger {
        switch kind {
        case .http:    return engineHTTP
        case .torrent: return engineTorrent
        case .sftp:    return engineSFTP
        case .ftp:     return engineFTP
        case .hls:     return engineHLS
        }
    }

    /// Non-Apple sink only: Apple's unified log filters and redacts itself, and a second floor here would defeat `log config`.
    enum Fallback {
        static let minimumLevel: GoelLogLevel = {
            guard let raw = ProcessInfo.processInfo.environment["GOEL_LOG_LEVEL"],
                  let level = GoelLogLevel.named(raw) else { return .notice }
            return level
        }()

        /// Off unless the operator opts in: stderr lands in a journal that outlives the process, so no user URLs by default.
        static let revealsPrivateValues: Bool = {
            let raw = ProcessInfo.processInfo.environment["GOEL_LOG_PRIVATE"]?.lowercased()
            return raw == "1" || raw == "true" || raw == "yes"
        }()
    }

    static let privatePlaceholder = "<private>"

    /// `os.Logger` applies privacy per interpolation segment, so one `.public` plus one `.private` blob is the only exact redaction boundary.
    static func split(_ fields: [GoelLogField]) -> (publicText: String, privateText: String) {
        var publicParts: [String] = []
        var privateParts: [String] = []
        for field in fields {
            let rendered = "\(field.label)=\(field.value)"
            if field.isPrivate { privateParts.append(rendered) } else { publicParts.append(rendered) }
        }
        return (publicParts.joined(separator: " "), privateParts.joined(separator: " "))
    }

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

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

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

    public func debug(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.debug, message, fields)
    }

    public func info(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.info, message, fields)
    }

    public func notice(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.notice, message, fields)
    }

    public func error(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.error, message, fields)
    }

    public func fault(_ message: StaticString, _ fields: GoelLogField...) {
        emit(.fault, message, fields)
    }

    public func log(_ level: GoelLogLevel, _ message: StaticString, fields: [GoelLogField]) {
        emit(level, message, fields)
    }

    private func emit(_ level: GoelLogLevel, _ message: StaticString, _ fields: [GoelLogField]) {
        #if canImport(os)
        let (publicText, privateText) = GoelLog.split(fields)
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
        // Unbuffered `fputs` to stderr keeps concurrent lines from interleaving mid-line without a lock of our own.
        fputs(line + "\n", stderr)
        #endif
    }
}

/// A stable, non-identifying token: `DownloadError.message` embeds server text and often the failing URL.
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
