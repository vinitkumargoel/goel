import XCTest
@testable import GoelCore

final class ReviewFixesTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    private func testSettings() -> AppSettings {
        AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.high.name,
            speedLimitEnabled: false,
            defaultSaveDirectory: saveDir
        )
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

    func testParseSourceEnforcesSchemeAllowlist() {
        if case .url = DownloadSource.parse("https://example.com/a.bin") {} else { XCTFail("https rejected") }
        if case .url = DownloadSource.parse("http://example.com/a.bin") {} else { XCTFail("http rejected") }
        if case .magnet = DownloadSource.parse("magnet:?xt=urn:btih:abc") {} else { XCTFail("magnet rejected") }
        if case .torrentFile = DownloadSource.parse("https://example.com/x.torrent") {} else { XCTFail(".torrent rejected") }

        XCTAssertEqual(DownloadSource.parse("ftp://host/file")?.kind, .ftp)
        XCTAssertEqual(DownloadSource.parse("sftp://host/file")?.kind, .sftp)

        XCTAssertNil(DownloadSource.parse("file:///etc/passwd"))
        XCTAssertNil(DownloadSource.parse("sftp:///onlypath"))
        XCTAssertNil(DownloadSource.parse("javascript:alert(1)"))
        XCTAssertNil(DownloadSource.parse("   "))
        XCTAssertNil(DownloadSource.parse("not a url"))
    }

    func testSanitizedNameStripsTraversal() {
        XCTAssertEqual(PathSafety.sanitizedName("../../.ssh/authorized_keys"), "authorized_keys")
        XCTAssertEqual(PathSafety.sanitizedName("/etc/passwd"), "passwd")
        XCTAssertEqual(PathSafety.sanitizedName(".."), "download")
        XCTAssertEqual(PathSafety.sanitizedName(".hidden"), "download")
        XCTAssertEqual(PathSafety.sanitizedName(""), "download")
        XCTAssertEqual(PathSafety.sanitizedName("normal.iso"), "normal.iso")
    }

    func testIsSavePathContained() {
        let safe = DownloadTask(source: .url(URL(string: "https://x/y")!), name: "file.bin", saveDirectory: "/Users/me/Downloads")
        XCTAssertTrue(safe.isSavePathContained)
        let evil = DownloadTask(source: .url(URL(string: "https://x/y")!), name: "../../etc/passwd", saveDirectory: "/Users/me/Downloads")
        XCTAssertFalse(evil.isSavePathContained)
    }

    func testMagnetTraversalNameIsNeutralised() async {
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http),
            torrentEngine: FakeEngine(kind: .torrent),
            settings: testSettings()
        )
        let a = await manager.add(source: .magnet("magnet:?xt=urn:btih:deadbeef&dn=../../evil"))
        XCTAssertEqual(a.name, "evil", "traversal must collapse to the last component")
        XCTAssertTrue(a.isSavePathContained)

        let b = await manager.add(source: .magnet("magnet:?xt=urn:btih:deadbee2&dn=/etc/passwd"))
        XCTAssertEqual(b.name, "passwd")
        XCTAssertTrue(b.isSavePathContained)
    }

    func testImportListSanitisesNames() throws {
        let store = try PersistenceStore()
        let hostile = DownloadTask(
            source: .url(URL(string: "https://x/y")!),
            name: "../../evil",
            saveDirectory: "/Users/me/Downloads"
        )
        let data = try JSONEncoder().encode([hostile])
        let imported = try store.importList(data)
        XCTAssertEqual(imported.first?.name, "evil")
        XCTAssertTrue(imported.first?.isSavePathContained ?? false)
    }

    func testRetryRequeuesFailedTask() async {
        let http = FakeEngine(kind: .http)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: FakeEngine(kind: .torrent),
            settings: testSettings()
        )
        let task = await manager.add(source: .url(URL(string: "https://example.test/retry.bin")!))
        _ = await waitUntil { http.added.contains(task.id) }

        http.emit(.failed(.network("boom")), for: task.id)
        let failed = await waitUntil {
            if case .failed = await manager.task(task.id)?.status { return true }
            return false
        }
        XCTAssertTrue(failed)

        await manager.resume(task.id)
        if case .failed = await manager.task(task.id)?.status {} else {
            XCTFail("resume() should not touch a .failed task")
        }

        await manager.retry(task.id)
        let revived = await waitUntil { await manager.task(task.id)?.status == .downloading }
        XCTAssertTrue(revived, "retry should re-queue and promote a failed task")
        XCTAssertTrue(http.resumed.contains(task.id), "the engine should be asked to re-run it")
    }

    func testValidateDiskSpaceRejectsOversizeAndUnqueryableDir() {
        XCTAssertThrowsError(try HTTPEngine.validateDiskSpace(directory: saveDir, needed: 10, maxAllowed: 1))
        // An unqueryable directory must THROW, not silently pass.
        XCTAssertThrowsError(try HTTPEngine.validateDiskSpace(directory: "/no/such/volume/xyz123456", needed: 1024))
        XCTAssertNoThrow(try HTTPEngine.validateDiskSpace(directory: saveDir, needed: 1024))
    }

    func testValidatorsDoNotResumeWithoutValidators() {
        XCTAssertFalse(SegmentedTransfer.validatorsAllowResume(
            cursorETag: nil, cursorLastModified: nil, probeETag: nil, probeLastModified: nil))
        XCTAssertTrue(SegmentedTransfer.validatorsAllowResume(
            cursorETag: "v1", cursorLastModified: nil, probeETag: "v1", probeLastModified: nil))
        XCTAssertFalse(SegmentedTransfer.validatorsAllowResume(
            cursorETag: "v1", cursorLastModified: nil, probeETag: "v2", probeLastModified: nil))
        XCTAssertTrue(SegmentedTransfer.validatorsAllowResume(
            cursorETag: nil, cursorLastModified: "Mon, 01 Jan 2024", probeETag: nil, probeLastModified: "Mon, 01 Jan 2024"))
    }
}
