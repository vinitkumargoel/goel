import Foundation
import GRDB

/// `@unchecked Sendable` rests entirely on `DatabaseQueue` serializing every access.
public final class PersistenceStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// WAL + synchronous=NORMAL: progress rows land every few seconds per task, and a rollback
    /// journal fsyncs twice per commit — WAL is durable across app crashes and far cheaper on the SSD.
    public init(path: String) throws {
        var config = Configuration()
        config.journalMode = .wal
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        self.encoder = Self.makeEncoder()
        self.decoder = JSONDecoder()
        try Self.migrator.migrate(dbQueue)
    }

    /// The file itself is damaged or isn't SQLite. Only then is moving it aside the cure — never for
    /// "locked by another copy" or "written by a newer version", where it would bury a good queue.
    public static func isCorruption(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
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
        migrator.registerMigration("v3-quarantine") { db in
            // Raw copies only: a newer build's rows, or a settings row we failed to read, survive
            // any later write that would otherwise replace them.
            try db.create(table: "task_quarantine") { t in
                t.column("id", .text).primaryKey()
                t.column("savedAt", .double).notNull()
                t.column("data", .blob).notNull()
            }
            try db.create(table: "settings_backup") { t in
                t.column("key", .text).primaryKey()
                t.column("savedAt", .double).notNull()
                t.column("data", .blob).notNull()
            }
        }
        return migrator
    }()

    /// Test seam for the WAL setting.
    func journalMode() throws -> String {
        try dbQueue.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
    }

    /// Test seam: plant a row this build can't decode, as a newer build would.
    func writeRawRow(table: String, key: String, data: Data) throws {
        try dbQueue.write { db in
            switch table {
            case "task":
                try db.execute(sql: "INSERT OR REPLACE INTO task (id, addedAt, status, data) VALUES (?, 0, 'future', ?)",
                               arguments: [key, data])
            default:
                try db.execute(sql: "INSERT OR REPLACE INTO settings (key, data) VALUES (?, ?)",
                               arguments: [key, data])
            }
        }
    }

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
        try loadAllTasksReport().tasks
    }

    /// Like ``loadAllTasks()``, but reports how many rows didn't decode (a newer build's enum case, a
    /// downgrade) and copies each raw row to `task_quarantine` so no later write can erase it.
    public func loadAllTasksReport() throws -> (tasks: [DownloadTask], skipped: Int) {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, data FROM task ORDER BY addedAt ASC")
            var tasks: [DownloadTask] = []
            var skipped = 0
            for row in rows {
                let data: Data = row["data"]
                if let task = try? self.decoder.decode(DownloadTask.self, from: data) {
                    tasks.append(task)
                    continue
                }
                skipped += 1
                let id: String = row["id"]
                try db.execute(
                    sql: "INSERT OR REPLACE INTO task_quarantine (id, savedAt, data) VALUES (?, ?, ?)",
                    arguments: [id, Date().timeIntervalSinceReferenceDate, data])
            }
            if skipped > 0 {
                GoelLog.persistence.error("Skipped undecodable task rows on load",
                                          .count(skipped, label: "rows"))
            }
            return (tasks, skipped)
        }
    }

    func quarantinedTaskCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_quarantine") ?? 0 }
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

    /// Copies the raw settings row, byte for byte, to `settings_backup` — run before defaults may be
    /// written over a row we failed to decode (portal token, password hash, feeds, proxy, folders).
    /// An existing backup is kept: a second failure would otherwise replace the original with a copy
    /// of the defaults-era row. Returns false when there was no row to back up (or one is already kept).
    @discardableResult
    public func backupSettingsRow() throws -> Bool {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT data FROM settings WHERE key = ?", arguments: [Self.settingsKey]
            ) else { return false }
            let data: Data = row["data"]
            try db.execute(
                sql: "INSERT OR IGNORE INTO settings_backup (key, savedAt, data) VALUES (?, ?, ?)",
                arguments: [Self.settingsKey, Date().timeIntervalSinceReferenceDate, data])
            return db.changesCount > 0
        }
    }

    /// The kept backup decoded, for "restore my old settings". Throws when it is still unreadable.
    public func decodeSettingsBackup() throws -> AppSettings? {
        guard let data = try loadSettingsBackup() else { return nil }
        return try decoder.decode(AppSettings.self, from: data)
    }

    /// Dropped once the backup has been adopted, so a later failure can keep a fresh one.
    public func clearSettingsBackup() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM settings_backup WHERE key = ?", arguments: [Self.settingsKey])
        }
    }

    public func loadSettingsBackup() throws -> Data? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT data FROM settings_backup WHERE key = ?",
                             arguments: [Self.settingsKey]).map { $0["data"] as Data }
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
            do {
                return try self.decoder.decode([String: [SpeedHistoryPoint]].self, from: data)
            } catch {
                GoelLog.persistence.error("Speed history undecodable — starting empty",
                                          .detail(String(describing: error)))
                return [:]
            }
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
            var skipped = 0
            let entries: [HistoryEntry] = rows.compactMap { row in
                let data: Data = row["data"]
                if let entry = try? self.decoder.decode(HistoryEntry.self, from: data) { return entry }
                skipped += 1
                return nil
            }
            if skipped > 0 {
                GoelLog.persistence.error("Skipped undecodable history rows",
                                          .count(skipped, label: "rows"))
            }
            return entries
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
    public func importList(_ data: Data,
                           defaultDirectory: String = AppSettings.systemDownloadsDirectory) throws -> [DownloadTask] {
        let decoded = try decoder.decode([DownloadTask].self, from: data)
        let tasks = decoded.map { Self.sanitizedForImport($0, defaultDirectory: defaultDirectory) }
        try saveTasks(tasks)
        return tasks
    }

    /// Imported files are untrusted. A shared backup naming `~/Library/LaunchAgents` would drop a plist
    /// that runs at login, and one claiming `completed` at `~/Documents/thesis.docx` would hand that file
    /// to "Remove and delete". So the folder is forced inside `defaultDirectory`, nothing starts on its
    /// own, and `completed` survives only when the payload is really at the sanitized path.
    public static func sanitizedForImport(
        _ task: DownloadTask,
        defaultDirectory: String = AppSettings.systemDownloadsDirectory
    ) -> DownloadTask {
        var t = task
        t.name = PathSafety.sanitizedName(t.name, fallback: "download")
        let dir = t.saveDirectory
        let wellFormed = dir.hasPrefix("/") && !dir.split(separator: "/").contains("..")
        if !wellFormed || !PathSafety.isContained(dir, within: defaultDirectory) {
            t.saveDirectory = defaultDirectory
        }
        if t.status == .completed, FileManager.default.fileExists(atPath: t.savePath) {
            t.fileMissing = nil
        } else if t.status != .paused {
            t.status = .paused
            t.completedAt = nil
        }
        t.retryAttempt = nil
        t.scheduledAt = nil
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
