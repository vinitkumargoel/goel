import Foundation
import GRDB

/// On-disk persistence for the download list and user settings, backed by GRDB.
///
/// The store survives quit & relaunch (a v1 requirement): every ``DownloadTask``
/// — including its resume position, error state and seeding state — and the
/// ``AppSettings`` are written to a SQLite database so the queue can be restored
/// exactly where the user left it.
///
/// Storage strategy is a pragmatic hybrid: each task is encoded to JSON and kept
/// in a `data` blob (so the full Codable model — files, resumeData and all —
/// round-trips losslessly and survives additive contract changes), alongside a
/// few promoted columns (`id`, `addedAt`, `status`) for ordering and querying.
/// Settings live in a single-row key/value table.
///
/// `DatabaseQueue` serializes all access internally, so the store is safe to call
/// from any isolation domain; it is marked `@unchecked Sendable` on that basis.
public final class PersistenceStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: Init

    /// Open (creating if needed) the database file at `path`.
    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        self.encoder = Self.makeEncoder()
        self.decoder = JSONDecoder()
        try Self.migrator.migrate(dbQueue)
    }

    /// Open a private in-memory database. Used by tests and ephemeral sessions.
    public init() throws {
        self.dbQueue = try DatabaseQueue()
        self.encoder = Self.makeEncoder()
        self.decoder = JSONDecoder()
        try Self.migrator.migrate(dbQueue)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Stable, sortable key order makes exported JSON diff-friendly.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: Schema

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "task") { t in
                t.column("id", .text).primaryKey()
                t.column("addedAt", .double).notNull()
                t.column("status", .text).notNull()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey()
                t.column("data", .blob).notNull()
            }
        }
        return migrator
    }()

    /// The fixed primary-key under which the singleton ``AppSettings`` is stored.
    private static let settingsKey = "app"

    // MARK: Tasks

    /// Insert or replace a single task. (Alias: ``upsert(_:)``.)
    public func saveTask(_ task: DownloadTask) throws {
        let data = try encoder.encode(task)
        try dbQueue.write { db in
            try Self.writeTask(task, data: data, into: db)
        }
    }

    /// Insert or replace a single task. Synonym for ``saveTask(_:)``.
    public func upsert(_ task: DownloadTask) throws {
        try saveTask(task)
    }

    /// Insert or replace several tasks in one transaction.
    public func saveTasks(_ tasks: [DownloadTask]) throws {
        let encoded = try tasks.map { ($0, try encoder.encode($0)) }
        try dbQueue.write { db in
            for (task, data) in encoded {
                try Self.writeTask(task, data: data, into: db)
            }
        }
    }

    /// Delete a task by id. No-op if it is not present.
    public func deleteTask(_ id: DownloadTask.ID) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Load every persisted task, ordered by `addedAt` (oldest first).
    public func loadAllTasks() throws -> [DownloadTask] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT data FROM task ORDER BY addedAt ASC")
            return try rows.map { row in
                let data: Data = row["data"]
                return try self.decoder.decode(DownloadTask.self, from: data)
            }
        }
    }

    private static func writeTask(_ task: DownloadTask, data: Data, into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO task (id, addedAt, status, data)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                addedAt = excluded.addedAt,
                status  = excluded.status,
                data    = excluded.data
            """,
            arguments: [
                task.id.uuidString,
                task.addedAt.timeIntervalSinceReferenceDate,
                statusKey(task.status),
                data,
            ]
        )
    }

    // MARK: Settings

    /// Persist the user settings (active profile, snail flag, default folder, …).
    public func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, data) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET data = excluded.data
                """,
                arguments: [Self.settingsKey, data]
            )
        }
    }

    /// Load the persisted settings, or `nil` if none were ever saved.
    public func loadSettings() throws -> AppSettings? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT data FROM settings WHERE key = ?",
                arguments: [Self.settingsKey]
            ) else { return nil }
            let data: Data = row["data"]
            return try self.decoder.decode(AppSettings.self, from: data)
        }
    }

    // MARK: Export / Import

    /// Export the full download list as a self-contained JSON array.
    public func exportList() throws -> Data {
        let tasks = try loadAllTasks()
        return try encoder.encode(tasks)
    }

    /// Import a JSON array previously produced by ``exportList()``, upserting each
    /// task. Returns the decoded tasks.
    @discardableResult
    public func importList(_ data: Data) throws -> [DownloadTask] {
        let decoded = try decoder.decode([DownloadTask].self, from: data)
        // Security: an imported file is untrusted input — re-sanitize each `name`
        // so it can't carry a path-traversal payload that would later be written
        // to / deleted from outside the save directory.
        // TODO(review): also clamp `saveDirectory` to an allowed root once a
        // settings/policy context is threaded into the store.
        let tasks = decoded.map { task -> DownloadTask in
            var t = task
            t.name = DownloadTask.sanitizedName(t.name, fallback: "download")
            return t
        }
        try saveTasks(tasks)
        return tasks
    }

    // MARK: Helpers

    /// A stable discriminator string for the promoted `status` column.
    private static func statusKey(_ status: DownloadStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .requestingMetadata: return "requestingMetadata"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .seeding: return "seeding"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}
