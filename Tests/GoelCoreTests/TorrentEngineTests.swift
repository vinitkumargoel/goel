import XCTest
@testable import GoelCore

final class TorrentEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-bt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testPriorityMappingRoundTrips() {
        XCTAssertEqual(TorrentEngine.toLibtorrentPriority(.skip), 0)
        XCTAssertEqual(TorrentEngine.toLibtorrentPriority(.low), 1)
        XCTAssertEqual(TorrentEngine.toLibtorrentPriority(.normal), 4)
        XCTAssertEqual(TorrentEngine.toLibtorrentPriority(.high), 7)

        XCTAssertEqual(TorrentEngine.fromLibtorrentPriority(0), .skip)
        XCTAssertEqual(TorrentEngine.fromLibtorrentPriority(1), .low)
        XCTAssertEqual(TorrentEngine.fromLibtorrentPriority(4), .normal)
        XCTAssertEqual(TorrentEngine.fromLibtorrentPriority(7), .high)
    }

    func testEngineHandlesTorrentKind() {
        let engine = TorrentEngine(profile: .high)
        XCTAssertTrue(engine.canHandle(.magnet("magnet:?xt=urn:btih:abc")))
        XCTAssertTrue(engine.canHandle(.torrentFile(URL(string: "https://x/y.torrent")!)))
        XCTAssertFalse(engine.canHandle(.url(URL(string: "https://x/y.bin")!)))
    }

    func testLiveTorrentDownloadsRealBytes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOEL_LIVE_NET"] == "1",
                          "set GOEL_LIVE_NET=1 to run the live network test")
        let torrentURL = try await discoverDebianTorrent()
        let engine = TorrentEngine(profile: .high)
        let task = DownloadTask(source: .torrentFile(torrentURL), name: "debian", saveDirectory: tempDir.path)
        let stream = engine.events(for: task.id)
        await engine.add(task)

        let target: Int64 = 3_000_000
        var maxBytes: Int64 = 0
        var resolved = false
        var failure: DownloadError?
        let deadline = Date().addingTimeInterval(180)

        let waiter = Task { () -> Void in
            for await event in stream {
                switch event {
                case let .metadataResolved(_, total, files):
                    resolved = total > 0 && !files.isEmpty
                case let .progress(downloaded, _, _, _, peers):
                    maxBytes = max(maxBytes, downloaded)
                    if downloaded >= target { return }
                    _ = peers
                case let .failed(error):
                    failure = error; return
                default:
                    break
                }
                if Date() > deadline { return }
            }
        }
        _ = await waiter.value
        await engine.remove(task.id, deleteData: true)

        XCTAssertNil(failure, "torrent must not fail: \(String(describing: failure))")
        XCTAssertTrue(resolved, "metadata (file list + total size) must resolve")
        XCTAssertGreaterThanOrEqual(maxBytes, target,
                                    "must transfer real bytes from the swarm/webseed (got \(maxBytes))")
    }

    func testResolveMetadataLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOEL_LIVE_NET"] == "1",
                          "set GOEL_LIVE_NET=1 to run the live network test")
        let torrentURL = try await discoverDebianTorrent()
        let engine = TorrentEngine(profile: .high)
        let meta = try await engine.resolveMetadata(for: .torrentFile(torrentURL), timeout: 60)
        let resolved = try XCTUnwrap(meta, "metadata must resolve from the .torrent")
        XCTAssertGreaterThan(resolved.totalBytes, 0)
        XCTAssertFalse(resolved.files.isEmpty, "the file list must be populated")
        XCTAssertFalse(resolved.name.isEmpty)
    }

    private func discoverDebianTorrent() async throws -> URL {
        let dir = URL(string: "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/")!
        let (data, _) = try await URLSession.shared.data(from: dir)
        let html = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"href="(debian-[^"]*netinst\.iso\.torrent)""#)
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let r = Range(match.range(at: 1), in: html) else {
            throw XCTSkip("couldn't locate a Debian netinst .torrent in the listing")
        }
        return dir.appendingPathComponent(String(html[r]))
    }
}
