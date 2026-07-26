import Foundation

// ============================================================================
// Audit log — a local, append-only compliance record.
//
// WHAT THIS IS. Regulated environments (finance, health, defence contractors,
// anyone under SOC 2 / ISO 27001) have to answer "what left or entered this
// machine, when, and under whose account?". This writes exactly that, as JSON
// Lines, to a file on the same machine.
//
// WHAT THIS IS NOT — and this is a product guarantee, not a preference:
//
//   * It is NEVER transmitted. There is no uploader, no endpoint, no
//     opportunistic "help us improve" batch. Nothing in this file opens a
//     socket, and nothing anywhere else in the app reads these files back.
//   * It is OFF BY DEFAULT. A personal user never produces a byte of it.
//   * It is redacted at the point of construction, not at the point of reading:
//     a record carries the URL's HOST ONLY. The path, the query string, the
//     fragment, and any embedded `user:password@` never enter the record in the
//     first place, so a leaked audit file cannot leak a signed download URL or
//     a credential. See ``AuditEvent/redactedHost(from:)``.
//
// Anyone auditing this codebase for the "no telemetry" claim should be able to
// read this header, grep the file for `URLSession`, find nothing, and move on.
//
// The format is JSON Lines (one self-contained JSON object per line) because it
// is append-only by construction — a crash mid-write costs at most the last
// line — and every SIEM, `jq` pipeline and spreadsheet import already reads it.
// ============================================================================

/// One line of the audit log.
///
/// Field choice is deliberately minimal: enough to answer a compliance question,
/// not enough to reconstruct what the user was actually looking at.
public struct AuditEvent: Codable, Sendable, Equatable {

    /// The three moments worth recording. Pause/resume/queue churn is noise for
    /// an auditor and is deliberately not logged.
    public enum Action: String, Codable, Sendable {
        case added
        case completed
        case failed
    }

    /// When it happened, in UTC.
    public var timestamp: Date
    public var action: Action
    /// The local account name. Who, not what.
    public var user: String
    /// The remote **host only** — `releases.example.com`. Never a full URL.
    /// `"magnet"` for magnet links (the info-hash identifies the content, so it
    /// is withheld) and `"unknown"` when no host can be parsed.
    public var host: String
    /// The URL scheme (`https`, `sftp`, `magnet`, …). A protocol fact, not identity.
    public var scheme: String
    /// Which engine handled it (`http`, `torrent`, `hls`, `ftp`, `sftp`).
    public var kind: String
    /// Bytes transferred at the moment of the record. `0` for `added`.
    public var bytes: Int64
    /// The destination **directory** — where data landed on this machine. The
    /// file name is omitted: a directory answers "did it leave the approved
    /// share?", a file name leaks the content.
    public var destination: String
    /// The task's UUID, so the three records for one download can be joined.
    public var taskID: String
    /// For ``Action/failed``: a stable, non-identifying failure token such as
    /// `http-403` or `diskFull`. `nil` otherwise — never a server message, which
    /// routinely echoes the failing URL back.
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

    // MARK: Redaction

    /// The host of a locator, and nothing else.
    ///
    /// This is the single function that stands between the audit log and a leaked
    /// pre-signed URL. It reads `URLComponents.host` — which by definition cannot
    /// contain the path, query, fragment, or the `user:password@` userinfo — and
    /// falls back to a constant rather than to the raw string, so a locator that
    /// fails to parse still cannot smuggle itself into the file.
    public static func redactedHost(from locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") { return "magnet" }
        guard let host = URLComponents(string: trimmed)?.host?.lowercased(),
              !host.isEmpty else { return "unknown" }
        return host
    }

    /// The scheme of a locator, lowercased, or `"unknown"`.
    public static func redactedScheme(from locator: String) -> String {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
              !scheme.isEmpty else { return "unknown" }
        return scheme
    }

    /// Build a record for a task. The only entry point production code should
    /// use — it applies the redaction rules rather than trusting the caller to.
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

    /// The local account name, or `"unknown"` in a sandbox that hides it.
    public static var currentUser: String {
        let name = NSUserName()
        return name.isEmpty ? "unknown" : name
    }

    // MARK: Serialisation

    /// The shared encoder: ISO-8601 timestamps (so `sort` and `jq` both behave)
    /// and sorted keys (so a diff between two audit files is meaningful).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// This record as one JSON Lines row, newline included.
    ///
    /// Pure, so the redaction contract can be asserted in tests without touching
    /// the filesystem — which is exactly how ``EnterpriseTests`` proves that no
    /// full URL survives.
    public func jsonLine() throws -> String {
        let data = try Self.encoder.encode(self)
        // A JSON string can carry an escaped `\n` but never a literal one, so the
        // encoded form is guaranteed to be a single line; the newline we append
        // is therefore always the record separator.
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

// MARK: - Writer

/// The append-only writer.
///
/// An actor because rotation is a read-modify-write over the same file that
/// concurrent completions are appending to; serialising through the actor is
/// what keeps a rotation from interleaving with an append and losing a record.
///
/// Disabled writers do no work at all: ``record(_:)`` returns before touching
/// the disk, so the default configuration costs one boolean check per event.
public actor AuditLog {

    /// Rotation and retention policy, mirrored from ``AppSettings``.
    public struct Configuration: Sendable, Equatable {
        /// Master switch. Off by default — see the file header.
        public var isEnabled: Bool
        /// Where the files live. `nil` ⇒ Application Support/GoelDownloader/Audit.
        public var directory: URL?
        /// The live file is rotated once it passes this size.
        public var maxFileBytes: Int
        /// How many rotated files to keep beside the live one.
        public var keepFiles: Int
        /// Rotated files older than this are deleted. `0` disables age pruning.
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

        /// Build the policy from user/managed settings. Kept here so the mapping
        /// from ``AppSettings`` lives next to the thing it configures.
        ///
        /// The megabyte figure is re-clamped to `1…1024` on the way in even though
        /// ``AppSettings/validated()`` already did it: `megabytes * 1024 * 1024`
        /// **traps** on `Int` overflow, and a hard crash is too sharp an edge to
        /// leave depending on a caller having gone through the boundary.
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

    /// The live file's name. Rotated files are `goel-audit-<ISO8601>.jsonl`.
    public static let fileName = "goel-audit.jsonl"

    private var configuration: Configuration
    /// Set once the destination directory has been created, so the common path
    /// is a plain append with no `FileManager` round-trip.
    private var preparedDirectory: URL?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Adopt a new policy. Turning the log off never deletes what is already on
    /// disk — an auditor's record is not the app's to discard.
    public func configure(_ configuration: Configuration) {
        if configuration.directory != self.configuration.directory { preparedDirectory = nil }
        self.configuration = configuration
    }

    /// The directory currently in use, or `nil` when logging is off.
    public func currentDirectory() -> URL? {
        configuration.isEnabled ? resolvedDirectory() : nil
    }

    /// Append one record. Silent no-op when disabled.
    ///
    /// Write failures are logged and swallowed: an unwritable audit directory is
    /// an operator problem, and failing a user's download because a compliance
    /// file could not be appended to would be a worse outcome than the gap.
    public func record(_ event: AuditEvent) {
        guard configuration.isEnabled else { return }
        guard let line = try? event.jsonLine() else { return }
        guard let directory = prepareDirectory() else { return }
        let url = directory.appendingPathComponent(Self.fileName)
        rotateIfNeeded(at: url)
        append(Data(line.utf8), to: url)
    }

    /// Convenience for the scheduler: record a task transition.
    public func record(_ action: AuditEvent.Action, task: DownloadTask,
                       at timestamp: Date = Date()) {
        guard configuration.isEnabled else { return }
        record(AuditEvent(action: action, task: task, at: timestamp))
    }

    // MARK: File handling

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

    /// Open-append-close rather than a cached `FileHandle`: the file is a
    /// compliance artefact an operator may rotate, archive or `mv` out from under
    /// us at any moment, and a cached descriptor would keep writing into the
    /// unlinked inode without anyone noticing.
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

    /// Rename the live file out of the way once it grows past the cap, then prune.
    private func rotateIfNeeded(at url: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= configuration.maxFileBytes else { return }
        let stamp = Self.stampFormatter.string(from: Date())
        let directory = url.deletingLastPathComponent()
        // Two rotations inside the same millisecond would otherwise collide and
        // the second would fail, leaving the live file to grow unbounded.
        var rotated = directory.appendingPathComponent("goel-audit-\(stamp).jsonl")
        var attempt = 1
        while manager.fileExists(atPath: rotated.path), attempt < 100 {
            rotated = directory.appendingPathComponent("goel-audit-\(stamp)-\(attempt).jsonl")
            attempt += 1
        }
        do {
            try manager.moveItem(at: url, to: rotated)
        } catch {
            // Losing the rotation is survivable — the file simply keeps growing —
            // so log it and carry on rather than dropping the record.
            GoelLog.persistence.error("Audit log rotation failed",
                                      .path(url.path), .detail(String(describing: error)))
            return
        }
        prune(in: url.deletingLastPathComponent())
    }

    /// Apply both retention rules to the rotated files: age first, then count.
    /// The live file is never a candidate.
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

    /// Filesystem-safe ISO-8601 (no colons — they are legal on APFS but a
    /// long-standing hazard on network shares and when the file is copied to a
    /// Windows collector).
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()
}
