import XCTest
import Foundation
@testable import GoelContracts
@testable import GoelCore

/// Pins the on-disk persistence schema and the domain-model round-trips that the
/// store depends on. Companion to ``GoldenContractTests`` (which pins the wire
/// shapes): this fixes the *storage* contract — that a store carrying the `v1`
/// (task + settings) and `v2-history` migrations round-trips every persisted model
/// losslessly. An Android build restoring an exported queue must satisfy the same.
///
/// The schema is pinned *behaviorally* — through the real migrated store — rather
/// than by inspecting private DDL, so it stays true to what the app actually does
/// on relaunch.
final class PersistenceSchemaTests: XCTestCase {

    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-golden-\(UUID().uuidString).sqlite").path
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: v1 — task + settings tables

    func test_v1_taskTable_roundTripsAcrossReopen() throws {
        let id = UUID()
        do {
            let store = try PersistenceStore(path: dbPath)
            var task = Self.fixtureTask(id: id)
            task.status = .failed(.httpStatus(410))
            task.resumeData = Data([1, 2, 3])
            try store.saveTask(task)
        }
        // Reopen the same file: migrations must be idempotent and the row decode.
        let reopened = try PersistenceStore(path: dbPath)
        let loaded = try reopened.loadAllTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, id)
        XCTAssertEqual(loaded.first?.status, .failed(.httpStatus(410)))
        XCTAssertEqual(loaded.first?.resumeData, Data([1, 2, 3]))
    }

    func test_v1_settingsTable_roundTrips() throws {
        let store = try PersistenceStore(path: dbPath)
        var settings = AppSettings()
        settings.retryCount = 7
        try store.saveSettings(settings)

        let loaded = try store.loadSettings()
        XCTAssertEqual(loaded?.retryCount, 7)
    }

    // MARK: v2 — history table

    func test_v2_historyTable_roundTrips() throws {
        let store = try PersistenceStore(path: dbPath)
        let entry = HistoryEntry(id: UUID(), name: "ubuntu.iso", locator: "https://h/ubuntu.iso",
                                 kind: .http, totalBytes: 4096, savePath: "/dl/ubuntu.iso",
                                 completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.saveHistoryEntry(entry)

        let history = try store.loadHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, entry.id)
        XCTAssertEqual(history.first?.name, "ubuntu.iso")
        XCTAssertEqual(history.first?.completedAt, entry.completedAt)
    }

    /// The store is created from scratch (both migrations run) and reopened (they
    /// don't re-run destructively): a single flow touching all three tables proves
    /// the migration set applies cleanly and idempotently.
    func test_migrations_applyCleanlyAndAreIdempotent() throws {
        let id = UUID()
        do {
            let store = try PersistenceStore(path: dbPath)
            try store.saveTask(Self.fixtureTask(id: id))
            try store.saveSettings(AppSettings())
            try store.saveHistoryEntry(HistoryEntry(id: id, name: "f", locator: "https://h/f",
                                                    kind: .http, totalBytes: 1, savePath: "/d/f",
                                                    completedAt: Date(timeIntervalSince1970: 1)))
        }
        let reopened = try PersistenceStore(path: dbPath)          // re-runs the migrator
        XCTAssertEqual(try reopened.loadAllTasks().count, 1)
        XCTAssertNotNil(try reopened.loadSettings())
        XCTAssertEqual(try reopened.loadHistory().count, 1)
    }

    // MARK: Domain round-trips (Codable stability)

    func test_downloadTask_encodeDecodeEncode_isStable() throws {
        let task = Self.fixtureTask(id: UUID())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]

        let once = try encoder.encode(task)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: once)
        let twice = try encoder.encode(decoded)

        XCTAssertEqual(once, twice, "DownloadTask JSON coding must be a stable fixed point")
        XCTAssertEqual(decoded, task)
    }

    func test_downloadTask_alwaysPresentKeys_arePinned() throws {
        // A default task carries only its non-optional fields — the storage
        // contract's mandatory column set. Renaming/removing any of these breaks
        // every persisted blob and every cross-language reader.
        let task = DownloadTask(source: .url(URL(string: "https://h/f.bin")!),
                                name: "f.bin", saveDirectory: "/dl")
        let data = try JSONEncoder().encode(task)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let required: Set<String> = [
            "id", "source", "name", "saveDirectory", "bytesDownloaded", "bytesUploaded",
            "downloadSpeed", "uploadSpeed", "status", "priority", "files",
            "connectionCount", "addedAt",
        ]
        XCTAssertTrue(required.isSubset(of: Set(dict.keys)),
                      "missing mandatory keys: \(required.subtracting(Set(dict.keys)))")
    }

    func test_appSettings_encodeDecodeEncode_isStable() throws {
        let settings = AppSettings()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]

        let once = try encoder.encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: once)
        let twice = try encoder.encode(decoded)

        XCTAssertEqual(once, twice, "AppSettings JSON coding must be a stable fixed point")
        XCTAssertEqual(decoded, settings)
    }

    // MARK: Fixture

    private static func fixtureTask(id: UUID) -> DownloadTask {
        DownloadTask(
            id: id,
            source: .url(URL(string: "https://example.com/file.bin")!),
            name: "file.bin",
            saveDirectory: "/downloads",
            totalBytes: 4096,
            bytesDownloaded: 1024,
            status: .downloading,
            priority: .normal,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tags: ["iso", "linux"]
        )
    }
}
