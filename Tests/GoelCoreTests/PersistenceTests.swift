import XCTest
@testable import GoelCore

final class PersistenceTests: XCTestCase {

    // MARK: Temp-file plumbing

    /// Temp DB paths created during a test, removed in tearDown.
    private var tempPaths: [String] = []

    private func tempDBPath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-persist-\(UUID().uuidString).sqlite")
        tempPaths.append(url.path)
        return url.path
    }

    override func tearDownWithError() throws {
        for path in tempPaths {
            // GRDB may create -wal / -shm sidecar files; remove them too.
            for suffix in ["", "-wal", "-shm"] {
                let p = path + suffix
                if FileManager.default.fileExists(atPath: p) {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }
        }
        tempPaths.removeAll()
    }

    // MARK: Fixtures

    private func urlSource(_ s: String) -> DownloadSource { .url(URL(string: s)!) }
    private func magnetSource(_ hash: String) -> DownloadSource {
        .magnet("magnet:?xt=urn:btih:\(hash)&dn=Demo+Pack")
    }

    /// A varied fixture set covering every storage-relevant shape: pre-metadata,
    /// in-progress, paused-with-resume-data, failed (with a concrete reason),
    /// seeding (upload bytes), completed, and a multi-file torrent.
    private func sampleTasks() -> [DownloadTask] {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

        let queued = DownloadTask(
            source: urlSource("https://example.test/a.bin"),
            name: "a.bin",
            saveDirectory: "/tmp/dl",
            status: .queued,
            addedAt: base
        )

        let downloading = DownloadTask(
            source: urlSource("https://example.test/b.bin"),
            name: "b.bin",
            saveDirectory: "/tmp/dl",
            totalBytes: 5000,
            bytesDownloaded: 1234,
            downloadSpeed: 999,
            status: .downloading,
            files: [TransferFile(id: 0, path: "b.bin", length: 5000, bytesCompleted: 1234)],
            connectionCount: 6,
            addedAt: base.addingTimeInterval(1),
            resumeData: Data([0x01, 0x02, 0x03, 0x04])
        )

        let failed = DownloadTask(
            source: urlSource("https://example.test/c.bin"),
            name: "c.bin",
            saveDirectory: "/tmp/dl",
            totalBytes: 9000,
            bytesDownloaded: 100,
            status: .failed(.diskFull(needed: 9000, available: 100)),
            addedAt: base.addingTimeInterval(2)
        )

        let seeding = DownloadTask(
            source: magnetSource("aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"),
            name: "Demo Pack",
            saveDirectory: "/tmp/dl",
            totalBytes: 8000,
            bytesDownloaded: 8000,
            bytesUploaded: 4000,
            status: .seeding,
            files: [
                TransferFile(id: 0, path: "Demo Pack/one.iso", length: 6000, bytesCompleted: 6000),
                TransferFile(id: 1, path: "Demo Pack/two.txt", length: 2000, bytesCompleted: 2000, priority: .low),
            ],
            connectionCount: 12,
            addedAt: base.addingTimeInterval(3),
            completedAt: base.addingTimeInterval(50),
            resumeData: Data([0xff, 0xee, 0xdd])
        )

        let completed = DownloadTask(
            source: urlSource("https://example.test/d.bin"),
            name: "d.bin",
            saveDirectory: "/tmp/dl",
            totalBytes: 4096,
            bytesDownloaded: 4096,
            status: .completed,
            addedAt: base.addingTimeInterval(4),
            completedAt: base.addingTimeInterval(60)
        )

        return [queued, downloading, failed, seeding, completed]
    }

    // MARK: (a) Tasks round-trip

    func testTasksRoundTrip() throws {
        let store = try PersistenceStore()
        let originals = sampleTasks()
        try store.saveTasks(originals)

        let reloaded = try store.loadAllTasks()

        // Identical set & order (loadAllTasks orders by addedAt).
        XCTAssertEqual(reloaded, originals, "every Codable field must survive the round-trip")

        // Spot-check the storage-critical, requirement-driven fields.
        let byName = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.name, $0) })
        XCTAssertEqual(byName["c.bin"]?.status, .failed(.diskFull(needed: 9000, available: 100)))
        XCTAssertEqual(byName["Demo Pack"]?.status, .seeding)
        XCTAssertEqual(byName["Demo Pack"]?.bytesUploaded, 4000)
        XCTAssertEqual(byName["Demo Pack"]?.files.count, 2)
        XCTAssertEqual(byName["b.bin"]?.resumeData, Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(byName["b.bin"]?.bytesDownloaded, 1234)
    }

    func testUpsertReplacesAndDeleteRemoves() throws {
        let path = tempDBPath()
        let store = try PersistenceStore(path: path)

        var task = sampleTasks()[1]   // the downloading one
        try store.upsert(task)

        task.bytesDownloaded = 4321
        task.status = .paused
        try store.upsert(task)        // same id → replace, not duplicate

        let afterUpsert = try store.loadAllTasks()
        XCTAssertEqual(afterUpsert.count, 1)
        XCTAssertEqual(afterUpsert.first?.bytesDownloaded, 4321)
        XCTAssertEqual(afterUpsert.first?.status, .paused)

        try store.deleteTask(task.id)
        XCTAssertTrue(try store.loadAllTasks().isEmpty)
    }

    // MARK: (b) Settings round-trip

    func testSettingsRoundTrip() throws {
        let store = try PersistenceStore()

        // Nothing saved yet.
        XCTAssertNil(try store.loadSettings())

        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: "Low",
            speedLimitEnabled: false,
            defaultSaveDirectory: "/Users/test/Downloads"
        )
        try store.saveSettings(settings)

        let reloaded = try store.loadSettings()
        XCTAssertEqual(reloaded, settings)
        XCTAssertEqual(reloaded?.selectedProfileName, "Low")
        XCTAssertFalse(reloaded?.speedLimitEnabled ?? true)
        XCTAssertEqual(reloaded?.defaultSaveDirectory, "/Users/test/Downloads")
    }

    // MARK: (c) Relaunch simulation — manager A persists, fresh manager B restores

    func testRelaunchRestoresTasksAndSettings() async throws {
        let path = tempDBPath()

        let settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: "Low",
            speedLimitEnabled: true,
            defaultSaveDirectory: "/tmp/relaunch"
        )

        // ---- Session A: add a mix of downloads, then drive them to varied states.
        let storeA = try PersistenceStore(path: path)
        let httpA = FakeEngine(kind: .http)
        let torrentA = FakeEngine(kind: .torrent)
        let managerA = DownloadManager(
            httpEngine: httpA,
            torrentEngine: torrentA,
            settings: settings,
            store: storeA
        )

        // A settings change is persisted through the manager (the realistic path).
        await managerA.setProfile("Low")

        let a = await managerA.add(source: urlSource("https://example.test/relaunch-a.bin"))
        let b = await managerA.add(source: urlSource("https://example.test/relaunch-b.bin"))

        // Drive `a` to a failed terminal state; give `b` progress + resume data.
        let started = await waitUntil { httpA.added.contains(a.id) && httpA.added.contains(b.id) }
        XCTAssertTrue(started)

        httpA.emit(.progress(bytesDownloaded: 2048, bytesUploaded: 0, downloadSpeed: 500, uploadSpeed: 0, connectionCount: 3), for: b.id)
        httpA.emit(.resumeDataUpdated(Data([0xAB, 0xCD])), for: b.id)
        httpA.emit(.failed(.timedOut), for: a.id)

        let drained = await waitUntil {
            let ta = await managerA.task(a.id)
            let tb = await managerA.task(b.id)
            return ta?.status == .failed(.timedOut)
                && tb?.bytesDownloaded == 2048
                && tb?.resumeData == Data([0xAB, 0xCD])
        }
        XCTAssertTrue(drained)

        // Let the off-actor persistence writes flush.
        let persistedToDisk = await waitUntil {
            let tasks = (try? storeA.loadAllTasks()) ?? []
            guard tasks.count == 2 else { return false }
            let b = tasks.first { $0.id == b.id }
            let a = tasks.first { $0.id == a.id }
            let settingsSaved = (try? storeA.loadSettings())?.selectedProfileName == "Low"
            return settingsSaved
                && b?.bytesDownloaded == 2048
                && b?.resumeData == Data([0xAB, 0xCD])
                && a?.status == .failed(.timedOut)
        }
        XCTAssertTrue(persistedToDisk)

        // ---- Session B: a brand-new store + manager over the SAME file restores.
        let storeB = try PersistenceStore(path: path)
        let managerB = DownloadManager(
            httpEngine: FakeEngine(kind: .http),
            torrentEngine: FakeEngine(kind: .torrent),
            store: storeB
        )
        await managerB.restore()

        let restored = await managerB.snapshot
        XCTAssertEqual(restored.count, 2)

        let rb = await managerB.task(b.id)
        let ra = await managerB.task(a.id)

        // Resume-eligible `b` comes back paused, but with bytes & resume data intact.
        XCTAssertEqual(rb?.status, .paused)
        XCTAssertEqual(rb?.bytesDownloaded, 2048)
        XCTAssertEqual(rb?.resumeData, Data([0xAB, 0xCD]))
        XCTAssertEqual(rb?.downloadSpeed, 0, "transient speed is cleared on restore")

        // Terminal failure is preserved verbatim, reason and all.
        XCTAssertEqual(ra?.status, .failed(.timedOut))

        // Settings were restored too.
        let restoredSettings = await managerB.currentSettings
        XCTAssertEqual(restoredSettings.selectedProfileName, "Low")
        XCTAssertEqual(restoredSettings.defaultSaveDirectory, "/tmp/relaunch")
    }

    // MARK: (d) Export then import yields the same list

    func testExportThenImportYieldsSameList() throws {
        let source = try PersistenceStore()
        let originals = sampleTasks()
        try source.saveTasks(originals)

        let exported = try source.exportList()
        XCTAssertFalse(exported.isEmpty)

        // Import into a completely separate store.
        let destination = try PersistenceStore()
        let imported = try destination.importList(exported)
        XCTAssertEqual(Set(imported), Set(originals))

        let reloaded = try destination.loadAllTasks()
        XCTAssertEqual(reloaded, originals, "export → import must reproduce the list exactly")
    }

    // MARK: Local helper

    /// Poll an async predicate until it holds or the timeout fires.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }
}
