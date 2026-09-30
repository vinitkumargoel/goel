import XCTest
@testable import GoelCore

final class PersistenceDurabilityTests: XCTestCase {

    private var tempDirs: [String] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-durability-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    private func manager(_ store: PersistenceStore, settings: AppSettings = AppSettings(),
                         http: RecordingEngine = RecordingEngine(kind: .http)) -> DownloadManager {
        DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent),
                        settings: settings, store: store)
    }

    // MARK: PERF-5

    func testFileStoreRunsInWALMode() throws {
        let path = (makeTempDir() as NSString).appendingPathComponent("queue.sqlite")
        let store = try PersistenceStore(path: path)
        XCTAssertEqual(try store.journalMode().lowercased(), "wal")
    }

    func testResumeDataIsCoalescedAndFlushedAtShutdown() async throws {
        let store = try PersistenceStore()
        let http = RecordingEngine(kind: .http)
        let manager = manager(store, http: http)
        let task = await manager.add(source: .url(URL(string: "https://example.test/r.bin")!),
                                     saveDirectory: makeTempDir())
        await waitUntil { http.log.contains("add:r.bin") }

        http.emit(.resumeDataUpdated(Data([1])), for: task.id)
        let first = await waitUntil { (try? store.loadAllTasks())?.first?.resumeData == Data([1]) }
        XCTAssertTrue(first, "the first cursor is written straight away")

        http.emit(.resumeDataUpdated(Data([2])), for: task.id)
        await waitUntil { await manager.task(task.id)?.resumeData == Data([2]) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try store.loadAllTasks().first?.resumeData, Data([1]),
                       "a second cursor within the window stays in memory")

        await manager.shutdown()
        XCTAssertEqual(try store.loadAllTasks().first?.resumeData, Data([2]), "shutdown flushes it")
    }

    // MARK: FAIL-3

    func testUndecodableRowsAreKeptAsideAndReported() async throws {
        let store = try PersistenceStore()
        let good = DownloadTask(source: .url(URL(string: "https://example.test/ok.bin")!),
                                name: "ok.bin", saveDirectory: makeTempDir(), status: .paused)
        try store.saveTask(good)
        try store.writeRawRow(table: "task", key: UUID().uuidString, data: Data(#"{"status":"hyperspace"}"#.utf8))

        let report = try store.loadAllTasksReport()
        XCTAssertEqual(report.tasks.map(\.id), [good.id])
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(try store.quarantinedTaskCount(), 1, "the raw row is copied where no upsert can reach it")

        let manager = manager(store)
        await manager.restore()
        let notices = await manager.takeNotices()
        XCTAssertTrue(notices.contains { $0.message.contains("1 downloads") || $0.message.contains("1 download") })
        let warning = await manager.currentPersistenceWarning
        XCTAssertNotNil(warning)
        await manager.shutdown()
    }

    // MARK: FAIL-4

    func testUnreadableSettingsAreBackedUpBeforeDefaultsOverwriteThem() async throws {
        let store = try PersistenceStore()
        let raw = Data("not json at all — imagine a portal token in here".utf8)
        try store.writeRawRow(table: "settings", key: "app", data: raw)

        let manager = manager(store)
        await manager.restore()
        let notices = await manager.takeNotices()
        XCTAssertFalse(notices.isEmpty, "the reset to defaults is announced")
        XCTAssertEqual(try store.loadSettingsBackup(), raw)

        await manager.setProfile("Low")
        await manager.shutdown()
        XCTAssertEqual(try store.loadSettings()?.selectedProfileName, "Low")
        XCTAssertEqual(try store.loadSettingsBackup(), raw, "the original survives the overwrite")
    }

    // MARK: SEC-2

    func testImportForcesTheFolderInsideTheSaveFolder() {
        let root = makeTempDir()
        let hostile = DownloadTask(source: .url(URL(string: "https://evil.test/com.x.plist")!),
                                   name: "com.x.plist",
                                   saveDirectory: NSHomeDirectory() + "/Library/LaunchAgents",
                                   status: .queued)
        let cleaned = PersistenceStore.sanitizedForImport(hostile, defaultDirectory: root)
        XCTAssertEqual(cleaned.saveDirectory, root)
        XCTAssertEqual(cleaned.status, .paused, "nothing from an import starts on its own")

        let nested = DownloadTask(source: .url(URL(string: "https://e.test/a")!), name: "a",
                                  saveDirectory: root + "/Music")
        XCTAssertEqual(PersistenceStore.sanitizedForImport(nested, defaultDirectory: root).saveDirectory,
                       root + "/Music", "a folder already inside the save folder is kept")
    }

    func testImportedCompletedClaimNeedsARealFile() {
        let root = makeTempDir()
        let path = (root as NSString).appendingPathComponent("real.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let real = DownloadTask(source: .url(URL(string: "https://e.test/real.bin")!), name: "real.bin",
                                saveDirectory: root, status: .completed, completedAt: Date())
        XCTAssertEqual(PersistenceStore.sanitizedForImport(real, defaultDirectory: root).status, .completed)

        let thesis = DownloadTask(source: .url(URL(string: "https://e.test/t")!), name: "thesis.docx",
                                  saveDirectory: NSHomeDirectory() + "/Documents",
                                  status: .completed, completedAt: Date())
        let cleaned = PersistenceStore.sanitizedForImport(thesis, defaultDirectory: root)
        XCTAssertEqual(cleaned.status, .paused, "a completed claim with no payload can't aim Remove-and-delete")
        XCTAssertEqual(cleaned.saveDirectory, root)
        XCTAssertNil(cleaned.completedAt)
    }

    func testImportEnvelopeSanitizesAgainstTheCurrentSaveFolder() async throws {
        let root = makeTempDir()
        var settings = AppSettings()
        settings.defaultSaveDirectory = root
        let manager = DownloadManager(httpEngine: RecordingEngine(kind: .http),
                                      torrentEngine: RecordingEngine(kind: .torrent),
                                      settings: settings, store: try PersistenceStore())
        let hostile = DownloadTask(source: .url(URL(string: "https://evil.test/x")!), name: "x",
                                   saveDirectory: "/etc", status: .downloading)
        let envelope = AppExport(settings: AppSettings(), tasks: [hostile])
        let added = try await manager.importEnvelope(JSONEncoder().encode(envelope))
        XCTAssertEqual(added, 1)
        let row = await manager.task(hostile.id)
        XCTAssertEqual(row?.saveDirectory, root)
        XCTAssertEqual(row?.status, .paused)
        await manager.shutdown()
    }

    // MARK: FAIL-20

    func testUnreadableSFTPFileIsAFailureNotAnEmptyList() throws {
        let dir = URL(fileURLWithPath: makeTempDir())
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("sftp-connections.json"))
        let store = SFTPConnectionStore(credentials: InMemoryCredentialStoreForDurability(), directory: dir)
        guard case .failure(.unreadable) = store.loadOutcome() else {
            return XCTFail("an unreadable file must be reported")
        }
        let empty = SFTPConnectionStore(credentials: InMemoryCredentialStoreForDurability(),
                                        directory: URL(fileURLWithPath: makeTempDir()))
        guard case .success(let list) = empty.loadOutcome() else { return XCTFail() }
        XCTAssertTrue(list.isEmpty, "a missing file is simply an empty list")
    }

    // MARK: UX-6

    func testAutoShutdownActionIsTypedAndUnknownMeansNone() {
        var s = AppSettings()
        s.autoShutdownAction = "reboot-into-bios"
        XCTAssertEqual(s.autoShutdown, .none)
        XCTAssertEqual(s.validated().autoShutdownAction, "none")
        s.autoShutdown = .sleep
        XCTAssertEqual(s.autoShutdownAction, "sleep", "raw values stay the persisted strings")
        XCTAssertEqual(DrainIntent(action: AutoShutdownAction.shutdown), .shutdown)
        XCTAssertNil(DrainIntent(action: AutoShutdownAction.none))
        let env = ReducerEnv(notify: NotifyPrefs(onAdded: false, onCompleted: false, onFailed: false,
                                                 onlyWhenInactive: false),
                             isAppActive: false, shutdown: .quit)
        XCTAssertEqual(env.autoShutdownAction, "quit")
    }

    // MARK: SEC-1

    #if os(macOS)
    func testQuarantineMarksFilesAndFolderContentsWithoutCredentials() throws {
        let dir = makeTempDir()
        let file = (dir as NSString).appendingPathComponent("Invoice.dmg")
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        Quarantine.mark(URL(fileURLWithPath: file),
                        sourceURL: URL(string: "https://user:secret@example.test/Invoice.dmg"),
                        referrer: URL(string: "https://example.test/"))
        let props = try URL(fileURLWithPath: file)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(props?[kLSQuarantineAgentNameKey as String] as? String, "Goel°")
        let data = props?[kLSQuarantineDataURLKey as String]
        let dataString = (data as? URL)?.absoluteString ?? (data as? String) ?? ""
        XCTAssertFalse(dataString.contains("secret"), "credentials never land in the xattr")

        let folder = (dir as NSString).appendingPathComponent("Season 1")
        try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        let inner = folder + "/sub/ep1.command"
        FileManager.default.createFile(atPath: inner, contents: Data("x".utf8))
        Quarantine.mark(URL(fileURLWithPath: folder), sourceURL: nil, referrer: nil)
        XCTAssertGreaterThan(getxattr(inner, "com.apple.quarantine", nil, 0, 0, 0), 0,
                             "multi-file payloads are marked all the way down")
    }
    #endif
}

private final class InMemoryCredentialStoreForDurability: CredentialManaging, @unchecked Sendable {
    func credential(forHost host: String) -> (username: String, password: String)? { nil }
    func setCredential(username: String, password: String, host: String) -> Bool { true }
    func removeCredential(host: String) -> Bool { true }
    func allCredentials() -> [HostCredential] { [] }
    func lookupCredential(forHost host: String) -> CredentialLookup { .notFound }
    func storeCredential(username: String, password: String, host: String) -> CredentialWrite { .stored }
}
