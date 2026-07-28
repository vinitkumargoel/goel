import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import GoelCore

/// BitTorrent engine regressions: the metadata preview must never touch the user's files or running
/// torrents, an unusable proxy must be stated not assumed, seed-ratio fallback decidable on paper.
final class TorrentRemediationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-bt-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: The preview must not touch the user's data

    /// The blocker: previewing a `.torrent` whose data is already on disk used to remove it with
    /// libtorrent's `delete_files`, so re-adding a finished torrent to re-seed wiped the payload.
    func testMetadataPreviewDoesNotDeleteExistingPayload() async throws {
        let saveDir = tempDir.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: 16_384)
        let payloadURL = saveDir.appendingPathComponent("goel.bin")
        try payload.write(to: payloadURL)

        let fixture = try writeSingleFileTorrent(name: "goel.bin", payload: payload)
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))

        let meta = await engine.resolveMetadata(for: .torrentFile(fixture), in: saveDir.path)
        // Fail CLOSED if the fixture were malformed: without a real resolve the
        // "file survived" assertion below would pass for the wrong reason.
        let resolved = try XCTUnwrap(meta, "the fixture .torrent must resolve")
        XCTAssertEqual(resolved.name, "goel.bin")
        XCTAssertEqual(resolved.totalBytes, Int64(payload.count))
        XCTAssertEqual(resolved.files.count, 1)

        // `remove_torrent(delete_files)` is serviced on libtorrent's disk thread,
        // so give the old behaviour every chance to happen before asserting.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path),
                      "the metadata preview must never delete the user's payload")
        withExtendedLifetime(engine) {}
    }

    /// And it must not write into the save folder: the probe belongs in a throwaway directory of its
    /// own, so no future regression can reach the user's files through it.
    func testMetadataPreviewLeavesTheSaveDirectoryUntouched() async throws {
        let saveDir = tempDir.appendingPathComponent("untouched", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5C, count: 16_384)
        let fixture = try writeSingleFileTorrent(name: "goel.bin", payload: payload)

        let before = try FileManager.default.contentsOfDirectory(atPath: saveDir.path).sorted()
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        _ = await engine.resolveMetadata(for: .torrentFile(fixture), in: saveDir.path)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let after = try FileManager.default.contentsOfDirectory(atPath: saveDir.path).sorted()
        XCTAssertEqual(before, after, "the preview must not create anything in the save folder")
        withExtendedLifetime(engine) {}
    }

    /// Previewing an ALREADY-added torrent used to hand back the live handle (libtorrent's duplicate
    /// default), so tearing down the probe evicted the running download. It must fail closed instead.
    func testMetadataPreviewOfARunningTorrentDoesNotEvictIt() async throws {
        let saveDir = tempDir.appendingPathComponent("running", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x31, count: 16_384)
        try payload.write(to: saveDir.appendingPathComponent("goel.bin"))
        let fixture = try writeSingleFileTorrent(name: "goel.bin", payload: payload)

        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let task = DownloadTask(source: .torrentFile(fixture), name: "goel.bin",
                                saveDirectory: saveDir.path)
        await engine.add(task)

        // The stream ends when `remove` finishes the task below, so the watcher
        // terminates on its own rather than needing cancellation.
        let watcher = Task { () -> Bool in
            for await event in engine.events(for: task.id) {
                if case .failed = event { return true }
            }
            return false
        }

        let meta = await engine.resolveMetadata(for: .torrentFile(fixture), in: saveDir.path)
        let preview = try XCTUnwrap(meta, "a duplicate preview reports a reason, it does not time out")
        XCTAssertFalse(preview.reachable, "previewing a duplicate must fail closed")
        XCTAssertNotNil(preview.failureNote, "and must say why, not imply 'no peers answered'")

        try await Task.sleep(nanoseconds: 2_000_000_000)
        await engine.remove(task.id, deleteData: false)
        let failed = await watcher.value
        XCTAssertFalse(failed, "the preview must not knock the running torrent out of the session")
    }

    /// A hard add failure (corrupt `.torrent`) must carry its real reason; it used to collapse into
    /// "No peers answered in time — you can still start", inviting a queue of something unworkable.
    func testMetadataPreviewReportsWhyItFailed() async throws {
        let corrupt = tempDir.appendingPathComponent("corrupt.torrent")
        try Data("not a torrent at all".utf8).write(to: corrupt)

        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let meta = await engine.resolveMetadata(for: .torrentFile(corrupt), in: tempDir.path)

        let preview = try XCTUnwrap(meta, "a parse failure is a reason, not a timeout")
        XCTAssertFalse(preview.reachable)
        let note = try XCTUnwrap(preview.failureNote)
        XCTAssertFalse(note.isEmpty, "the failure note must actually say something")
        withExtendedLifetime(engine) {}
    }

    /// `TransferFile.path` is relative to the save folder. The bridge used to report only the last
    /// component, so same-named files in different subfolders collided in the picker and portal.
    func testResolvedFilesCarryTheirRelativePath() async throws {
        let fixture = try writeMultiFileTorrent()
        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let meta = await engine.resolveMetadata(for: .torrentFile(fixture), in: tempDir.path)

        let resolved = try XCTUnwrap(meta, "the fixture .torrent must resolve")
        XCTAssertEqual(resolved.files.count, 2)
        let paths = resolved.files.map(\.path).sorted()
        XCTAssertTrue(paths[0].hasSuffix("one/clip.bin"), "got \(paths[0])")
        XCTAssertTrue(paths[1].hasSuffix("two/clip.bin"), "got \(paths[1])")
        XCTAssertNotEqual(paths[0], paths[1], "same-named files in different folders must differ")
        withExtendedLifetime(engine) {}
    }

    // MARK: Fast resume

    /// Pausing must leave a libtorrent resume blob, so the next launch restores the lifetime upload
    /// total instead of overwriting it with a fresh zero (and re-hashing every piece).
    func testPauseWritesAFastResumeBlob() async throws {
        let saveDir = tempDir.appendingPathComponent("resume", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x77, count: 16_384)
        try payload.write(to: saveDir.appendingPathComponent("goel.bin"))
        let fixture = try writeSingleFileTorrent(name: "goel.bin", payload: payload)

        let engine = TorrentEngine(profile: .low, config: .init(enableDHT: false, enableLSD: false))
        let task = DownloadTask(source: .torrentFile(fixture), name: "goel.bin",
                                saveDirectory: saveDir.path)
        await engine.add(task)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await engine.pause(task.id)

        let blob = try XCTUnwrap(resumeFileURL(task.id))
        addTeardownBlock { try? FileManager.default.removeItem(at: blob) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path),
                      "pausing a torrent must persist its resume data")
        let size = (try FileManager.default.attributesOfItem(atPath: blob.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "the resume blob must not be empty")

        // Removing the task takes the orphaned blob with it.
        await engine.remove(task.id, deleteData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path),
                       "removing a task must not leave its resume blob behind")
    }

    // MARK: Pure policy

    func testSwarmProxyResolutionCoversEveryMode() {
        let none = SwarmProxy.resolve(.init(mode: "none"))
        XCTAssertEqual(none.setting.kind, .none)
        XCTAssertNil(none.gap, "asking for no proxy is not a gap")

        let system = SwarmProxy.resolve(.init(mode: "system"))
        XCTAssertEqual(system.setting.kind, .none, "libtorrent cannot read the OS proxy")
        XCTAssertEqual(system.gap, .systemProxyUnsupported)

        let socks = SwarmProxy.resolve(.init(mode: "manual", type: "socks5",
                                             host: "127.0.0.1", port: 1080))
        XCTAssertEqual(socks.setting.kind, .socks5)
        XCTAssertEqual(socks.setting.host, "127.0.0.1")
        XCTAssertEqual(socks.setting.port, 1080)
        XCTAssertTrue(socks.setting.peerConnections, "SOCKS5 carries peer connections")
        XCTAssertNil(socks.gap)

        let http = SwarmProxy.resolve(.init(mode: "manual", type: "http",
                                            host: "proxy.local", port: 3128))
        XCTAssertEqual(http.setting.kind, .http)
        XCTAssertFalse(http.setting.peerConnections, "an HTTP proxy cannot carry peers")
        XCTAssertEqual(http.gap, .httpProxyPeersDirect)

        let incomplete = SwarmProxy.resolve(.init(mode: "manual", type: "socks5",
                                                  host: "127.0.0.1", port: 0))
        XCTAssertEqual(incomplete.setting.kind, .none, "half a proxy is no proxy")
        XCTAssertEqual(incomplete.gap, .incompleteManual)

        let noHost = SwarmProxy.resolve(.init(mode: "manual", type: "socks5", host: "", port: 1080))
        XCTAssertEqual(noHost.setting.kind, .none)
        XCTAssertEqual(noHost.gap, .incompleteManual)
    }

    func testEffectiveSeedRatioPrefersTaskOverProfile() {
        // No per-task limit: the profile's global "stop seeding at ratio" applies
        // — it used to be attached to nothing at all.
        XCTAssertEqual(TorrentEngine.effectiveSeedRatio(task: nil, profile: 1.5), 1.5)
        // A per-task limit wins.
        XCTAssertEqual(TorrentEngine.effectiveSeedRatio(task: 3.0, profile: 1.5), 3.0)
        // An explicit 0 means "seed this one indefinitely" and beats the profile.
        XCTAssertNil(TorrentEngine.effectiveSeedRatio(task: 0, profile: 1.5))
        // A profile of 0 imposes nothing.
        XCTAssertNil(TorrentEngine.effectiveSeedRatio(task: nil, profile: 0))
        XCTAssertEqual(TorrentEngine.effectiveSeedRatio(task: 2.0, profile: 0), 2.0)
    }

    func testSessionConfigCarriesPeX() {
        XCTAssertTrue(TorrentEngine.SessionConfig().enablePeX, "PeX is on unless the user turns it off")
        var config = TorrentEngine.SessionConfig()
        config.enablePeX = false
        XCTAssertNotEqual(config, TorrentEngine.SessionConfig(),
                          "the PeX choice must be part of the session identity, not dropped")
    }

    // MARK: Fixtures

    /// Mirror of the engine's own resume-blob location, so the test can look for
    /// the file the engine would have written.
    private func resumeFileURL(_ id: UUID) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GoelDownloader", isDirectory: true)
            .appendingPathComponent("TorrentResume", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".resume")
    }

    /// A minimal, valid v1 single-file `.torrent`. No announce list — nothing in
    /// these tests may talk to a tracker.
    private func writeSingleFileTorrent(name: String, payload: Data) throws -> URL {
        var info = Data("d6:lengthi\(payload.count)e".utf8)
        info.append(Data("4:name\(name.utf8.count):\(name)".utf8))
        info.append(Data("12:piece lengthi\(payload.count)e".utf8))
        info.append(Data("6:pieces20:".utf8))
        info.append(sha1(payload))
        info.append(Data("e".utf8))

        var torrent = Data("d4:info".utf8)
        torrent.append(info)
        torrent.append(Data("e".utf8))

        let url = tempDir.appendingPathComponent("\(UUID().uuidString).torrent")
        try torrent.write(to: url)
        return url
    }

    /// A minimal v1 multi-file `.torrent` with two identically-named files in
    /// different subfolders — the case a bare file name cannot describe.
    private func writeMultiFileTorrent() throws -> URL {
        let first = Data(repeating: 0x01, count: 8_192)
        let second = Data(repeating: 0x02, count: 8_192)
        let total = first.count + second.count

        var files = Data("5:filesl".utf8)
        for folder in ["one", "two"] {
            files.append(Data("d6:lengthi8192e4:pathl3:\(folder)8:clip.binee".utf8))
        }
        files.append(Data("e".utf8))

        var info = Data("d".utf8)
        info.append(files)
        info.append(Data("4:name8:goelpack".utf8))
        info.append(Data("12:piece lengthi\(total)e".utf8))
        info.append(Data("6:pieces20:".utf8))
        info.append(sha1(first + second))
        info.append(Data("e".utf8))

        var torrent = Data("d4:info".utf8)
        torrent.append(info)
        torrent.append(Data("e".utf8))

        let url = tempDir.appendingPathComponent("\(UUID().uuidString).torrent")
        try torrent.write(to: url)
        return url
    }

    private func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
}
