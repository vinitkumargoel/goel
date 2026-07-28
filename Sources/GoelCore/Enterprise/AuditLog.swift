import Foundation

// This log is never transmitted — there is no socket here — and every field is redacted at construction.

public struct AuditEvent: Codable, Sendable, Equatable {

    public enum Action: String, Codable, Sendable {
        case added
        case completed
        case failed
    }

    public var timestamp: Date
    public var action: Action
    public var user: String
    /// Host only, never a full URL; magnets record `"magnet"` because the info-hash identifies content.
    public var host: String
    public var scheme: String
    public var kind: String
    public var bytes: Int64
    /// Directory only — the file name leaks the content.
    public var destination: String
    public var taskID: String
    /// A stable token, never a server message: those routinely echo the failing URL back.
    public var outcome: String?

    public init(timestamp: Date = Date(), action: Action, user: String, host: String,
                scheme: String, kind: String, bytes: Int64, destination: String,
                taskID: String, outcome: String? = nil) {
        self.timestamp = timestamp
        self.action = action
        self.user = user
        self.host = host
        self.scheme = scheme
        self.kind = kind
        self.bytes = bytes
        self.destination = destination
        self.taskID = taskID
        self.outcome = outcome
    }

    /// Host and nothing else: this is what stops a pre-signed URL's path/query/userinfo reaching the log.
    public static func redactedHost(from locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") { return "magnet" }
        guard let host = URLComponents(string: trimmed)?.host?.lowercased(),
              !host.isEmpty else { return "unknown" }
        return host
    }

    public static func redactedScheme(from locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
              !scheme.isEmpty else { return "unknown" }
        return scheme
    }

    /// The only initialiser production code may use: it applies the redaction rules itself.
    public init(action: Action, task: DownloadTask, at timestamp: Date = Date(),
                user: String = AuditEvent.currentUser) {
        let locator = task.source.locator
        var outcome: String?
        if action == .failed, case .failed(let error) = task.status {
            outcome = DiagnosticsErrorLabel.of(error)
        }
        self.init(timestamp: timestamp,
                  action: action,
                  user: user,
                  host: Self.redactedHost(from: locator),
                  scheme: Self.redactedScheme(from: locator),
                  kind: task.kind.rawValue,
                  bytes: action == .added ? 0 : task.bytesDownloaded,
                  destination: task.saveDirectory,
                  taskID: task.id.uuidString,
                  outcome: outcome)
    }

    public static var currentUser: String {
        let name = NSUserName()
        return name.isEmpty ? "unknown" : name
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public func jsonLine() throws -> String {
        let data = try Self.encoder.encode(self)
        // JSON escapes every literal newline, so the encoded form is one line and this `\n` separates records.
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// An actor because rotation is a read-modify-write racing appends; interleaving would lose a record.
public actor AuditLog {

    public struct Configuration: Sendable, Equatable {
        public var isEnabled: Bool
        public var directory: URL?
        public var maxFileBytes: Int
        public var keepFiles: Int
        /// `0` disables age pruning.
        public var retentionDays: Int

        public init(isEnabled: Bool = false, directory: URL? = nil,
                    maxFileBytes: Int = 8 * 1024 * 1024, keepFiles: Int = 12,
                    retentionDays: Int = 90) {
            self.isEnabled = isEnabled
            self.directory = directory
            self.maxFileBytes = max(1024, maxFileBytes)
            self.keepFiles = max(0, keepFiles)
            self.retentionDays = max(0, retentionDays)
        }

        /// Re-clamp megabytes to `1…1024` even though `validated()` did: `mb * 1024 * 1024` traps on overflow.
        public init(settings: AppSettings) {
            let directory = settings.auditLogDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let megabytes = min(max(1, settings.auditLogMaxFileMegabytes), 1024)
            self.init(isEnabled: settings.auditLogEnabled,
                      directory: directory.isEmpty ? nil : URL(fileURLWithPath: directory),
                      maxFileBytes: megabytes * 1024 * 1024,
                      keepFiles: settings.auditLogKeepFiles,
                      retentionDays: settings.auditLogRetentionDays)
        }
    }

    public static let fileName = "goel-audit.jsonl"

    private var configuration: Configuration
    private var preparedDirectory: URL?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Turning the log off must never delete what is on disk — it is not the app's record to discard.
    public func configure(_ configuration: Configuration) {
        if configuration.directory != self.configuration.directory { preparedDirectory = nil }
        self.configuration = configuration
    }

    public func currentDirectory() -> URL? {
        configuration.isEnabled ? resolvedDirectory() : nil
    }

    /// Write failures are swallowed on purpose: an unwritable audit directory must not fail a download.
    public func record(_ event: AuditEvent) {
        guard configuration.isEnabled else { return }
        guard let line = try? event.jsonLine() else { return }
        guard let directory = prepareDirectory() else { return }
        let url = directory.appendingPathComponent(Self.fileName)
        rotateIfNeeded(at: url)
        append(Data(line.utf8), to: url)
    }

    public func record(_ action: AuditEvent.Action, task: DownloadTask,
                       at timestamp: Date = Date()) {
        guard configuration.isEnabled else { return }
        record(AuditEvent(action: action, task: task, at: timestamp))
    }

    private func resolvedDirectory() -> URL {
        configuration.directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GoelDownloader", isDirectory: true)
                .appendingPathComponent("Audit", isDirectory: true)
    }

    private func prepareDirectory() -> URL? {
        if let preparedDirectory { return preparedDirectory }
        let directory = resolvedDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            GoelLog.persistence.error("Audit log directory could not be created",
                                      .path(directory.path), .detail(String(describing: error)))
            return nil
        }
        preparedDirectory = directory
        return directory
    }

    /// Never cache the `FileHandle`: if an operator archives the file, the descriptor writes to a dead inode.
    private func append(_ data: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            GoelLog.persistence.error("Audit log is not writable", .path(url.path))
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            GoelLog.persistence.error("Audit log append failed",
                                      .path(url.path), .detail(String(describing: error)))
        }
    }

    private func rotateIfNeeded(at url: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= configuration.maxFileBytes else { return }
        let stamp = Self.stampFormatter.string(from: Date())
        let directory = url.deletingLastPathComponent()
        // Two rotations in the same millisecond collide; the failed one leaves the live file growing.
        var rotated = directory.appendingPathComponent("goel-audit-\(stamp).jsonl")
        var attempt = 1
        while manager.fileExists(atPath: rotated.path), attempt < 100 {
            rotated = directory.appendingPathComponent("goel-audit-\(stamp)-\(attempt).jsonl")
            attempt += 1
        }
        do {
            try manager.moveItem(at: url, to: rotated)
        } catch {
            GoelLog.persistence.error("Audit log rotation failed",
                                      .path(url.path), .detail(String(describing: error)))
            return
        }
        prune(in: url.deletingLastPathComponent())
    }

    private func prune(in directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        var archives = names
            .filter { $0.hasPrefix("goel-audit-") && $0.hasSuffix(".jsonl") }
            .sorted()   // the ISO-8601 stamp sorts chronologically as text
        if configuration.retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(configuration.retentionDays) * 86_400)
            archives.removeAll { name in
                let path = directory.appendingPathComponent(name)
                guard let attributes = try? manager.attributesOfItem(atPath: path.path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified < cutoff else { return false }
                try? manager.removeItem(at: path)
                return true
            }
        }
        guard archives.count > configuration.keepFiles else { return }
        for name in archives.prefix(archives.count - configuration.keepFiles) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// No colons in the stamp: legal on APFS, but they break network shares and Windows collectors.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()
}
