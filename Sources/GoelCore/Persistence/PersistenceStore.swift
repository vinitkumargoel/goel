import Foundation
import GRDB

/// `@unchecked Sendable` rests entirely on `DatabaseQueue` serializing every access.
public final class PersistenceStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        self.encoder = Self.makeEncoder()
        self.decoder = JSONDecoder()
        try Self.migrator.migrate(dbQueue)
    }

    public init() throws {
        self.dbQueue = try DatabaseQueue()
        self.encoder = Self.makeEncoder()
        self.decoder = JSONDecoder()
        try Self.migrator.migrate(dbQueue)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

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
        migrator.registerMigration("v2-history") { db in
            try db.create(table: "history") { t in
                t.column("id", .text).primaryKey()
                t.column("completedAt", .double).notNull()
                t.column("data", .blob).notNull()
            }
        }
        return migrator
    }()

    private static let settingsKey = "app"

    public func saveTask(_ task: DownloadTask) throws {
        let data = try encoder.encode(task)
        try dbQueue.write { db in
            try Self.writeTask(task, data: data, into: db)
        }
    }

    public func upsert(_ task: DownloadTask) throws {
        try saveTask(task)
    }

    public func saveTasks(_ tasks: [DownloadTask]) throws {
        let encoded = try tasks.map { ($0, try encoder.encode($0)) }
        try dbQueue.write { db in
            for (task, data) in encoded {
                try Self.writeTask(task, data: data, into: db)
            }
        }
    }

    public func deleteTask(_ id: DownloadTask.ID) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Undecodable rows are skipped on purpose: one corrupt task must not take the whole queue with it.
    public func loadAllTasks() throws -> [DownloadTask] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT data FROM task ORDER BY addedAt ASC")
            var skipped = 0
            let tasks: [DownloadTask] = rows.compactMap { row in
                let data: Data = row["data"]
                if let task = try? self.decoder.decode(DownloadTask.self, from: data) {
                    return task
                }
                skipped += 1
                return nil
            }
            if skipped > 0 {
                GoelLog.persistence.error("Skipped corrupt task rows on load",
                                          .count(skipped, label: "rows"))
            }
            return tasks
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

    public func saveSettings(_ settings: AppSettings) throws {
        try upsertBlob(key: Self.settingsKey, data: encoder.encode(settings))
    }

    private func upsertBlob(key: String, data: Data) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, data) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET data = excluded.data
                """,
                arguments: [key, data]
            )
        }
    }

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

    private static let statsKey = "stats"

    public func saveStats(_ stats: TransferStats) throws {
        try upsertBlob(key: Self.statsKey, data: encoder.encode(stats))
    }

    public func loadStats() throws -> TransferStats? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT data FROM settings WHERE key = ?",
                arguments: [Self.statsKey]
            ) else { return nil }
            let data: Data = row["data"]
            return try self.decoder.decode(TransferStats.self, from: data)
        }
    }

    private static let speedHistoryKey = "speedHistory"

    public func saveSpeedHistory(_ history: [String: [SpeedHistoryPoint]]) throws {
        try upsertBlob(key: Self.speedHistoryKey, data: encoder.encode(history))
    }

    public func loadSpeedHistory() throws -> [String: [SpeedHistoryPoint]] {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT data FROM settings WHERE key = ?",
                arguments: [Self.speedHistoryKey]
            ) else { return [:] }
            let data: Data = row["data"]
            return (try? self.decoder.decode([String: [SpeedHistoryPoint]].self, from: data)) ?? [:]
        }
    }

    public func saveHistoryEntry(_ entry: HistoryEntry) throws {
        let data = try encoder.encode(entry)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO history (id, completedAt, data) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    completedAt = excluded.completedAt,
                    data        = excluded.data
                """,
                arguments: [entry.id.uuidString,
                            entry.completedAt.timeIntervalSinceReferenceDate,
                            data]
            )
        }
    }

    public func loadHistory(limit: Int = 1000) throws -> [HistoryEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT data FROM history ORDER BY completedAt DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { row in
                let data: Data = row["data"]
                return try? self.decoder.decode(HistoryEntry.self, from: data)
            }
        }
    }

    public func deleteHistoryEntry(_ id: UUID) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func clearHistory() throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history")
        }
    }

    public func exportList() throws -> Data {
        let tasks = try loadAllTasks()
        return try encoder.encode(tasks)
    }

    public func exportTasks(_ tasks: [DownloadTask]) throws -> Data {
        try encoder.encode(tasks)
    }

    @discardableResult
    public func importList(_ data: Data) throws -> [DownloadTask] {
        let decoded = try decoder.decode([DownloadTask].self, from: data)
        let tasks = decoded.map(Self.sanitizedForImport)
        try saveTasks(tasks)
        return tasks
    }

    /// Imported files are untrusted: sanitize `name` and reject `..`/relative `saveDirectory` (arbitrary write).
    public static func sanitizedForImport(_ task: DownloadTask) -> DownloadTask {
        var t = task
        t.name = PathSafety.sanitizedName(t.name, fallback: "download")
        let dir = t.saveDirectory
        if !dir.hasPrefix("/") || dir.split(separator: "/").contains("..") {
            t.saveDirectory = AppSettings.systemDownloadsDirectory
        }
        return t
    }

    private static func statusKey(_ status: DownloadStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .requestingMetadata: return "requestingMetadata"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .paused: return "paused"
        case .seeding: return "seeding"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}
