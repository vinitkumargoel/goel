import XCTest
@testable import GoelCore

final class HLSJobLifecycleTests: XCTestCase {

    private let base = URL(string: "https://cdn.example.com/v/index.m3u8")!

    /// Never answers: the job stays parked on its first fetch until it is cancelled.
    final class SilentProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private func silentEngine() -> HLSEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SilentProtocol.self]
        return HLSEngine(profile: .high, configuration: config)
    }

    /// A finishing job must not clear the slot its paused-then-resumed successor now holds.
    func testStaleJobTokenCannotClearTheLiveJob() async {
        let engine = silentEngine()
        let task = DownloadTask(source: .hlsStream(base), name: "clip.mp4",
                                saveDirectory: FileManager.default.temporaryDirectory.path)
        await engine.add(task)
        await engine.clearJob(task.id, token: UUID())
        let stillTracked = await engine.hasJob(task.id)
        XCTAssertTrue(stillTracked, "a stale job's cleanup erased the live job, so pause could no longer reach it")
        await engine.remove(task.id, deleteData: false)
        let cleared = await engine.hasJob(task.id)
        XCTAssertFalse(cleared)
    }

    /// A rename or fresh cookie made while paused must reach the next run, not the add-time copy.
    func testRefreshReplacesTheStoredTaskOnlyWhileTracked() async {
        let engine = silentEngine()
        var task = DownloadTask(source: .hlsStream(base), name: "a.mp4",
                                saveDirectory: FileManager.default.temporaryDirectory.path)
        await engine.refresh(task)
        let ghost = await engine.storedTask(task.id)
        XCTAssertNil(ghost, "refresh must never resurrect a removed task")

        await engine.add(task)
        task.name = "b.mp4"
        task.cookieHeader = "session=fresh"
        await engine.refresh(task)
        let stored = await engine.storedTask(task.id)
        XCTAssertEqual(stored?.name, "b.mp4")
        XCTAssertEqual(stored?.cookieHeader, "session=fresh")
        await engine.remove(task.id, deleteData: false)
    }

    // MARK: - IV

    private func keyedPlaylist(iv: String, method: String = "AES-128") -> String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=\(method),URI="key.bin",IV=\(iv)
        #EXTINF:6.0,
        seg0.ts
        #EXT-X-ENDLIST
        """
    }

    /// The IV is a 128-bit integer: a packager that drops leading zeros still means the same IV.
    func testShortIVIsLeftPaddedNotRefused() throws {
        guard case .media(let segs, _, _, _)? = HLSParser.parse(keyedPlaylist(iv: "0x0102030405060708"),
                                                                baseURL: base) else {
            return XCTFail("a short IV is a valid integer")
        }
        XCTAssertEqual(segs.first?.key?.iv,
                       Data(repeating: 0, count: 8) + Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(HLSParser.ivData("0x1"), Data(repeating: 0, count: 15) + Data([1]))
    }

    func testOverlongIVRejectsThePlaylist() {
        XCTAssertNil(HLSParser.parse(keyedPlaylist(iv: "0x" + String(repeating: "01", count: 17)), baseURL: base))
    }

    /// A SAMPLE-AES/DRM line must reach the "can't decrypt" refusal, not die as "not a valid playlist".
    func testIVIsOnlyValidatedForAES128() throws {
        guard case .media(let segs, _, _, _)? = HLSParser.parse(keyedPlaylist(iv: "junk", method: "SAMPLE-AES"),
                                                                baseURL: base) else {
            return XCTFail("the playlist parses; the engine refuses the method later")
        }
        guard case .unsupported? = segs.first?.key?.method else { return XCTFail("method must be unsupported") }
    }

    func testMalformedIVRejectsThePlaylist() {
        XCTAssertNil(HLSParser.parse(keyedPlaylist(iv: "0xZZ0102030405060708090A0B0C0D0E0F"), baseURL: base))
    }

    func testSixteenByteIVIsKept() throws {
        let text = keyedPlaylist(iv: "0x000102030405060708090A0B0C0D0E0F")
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("a valid IV must still parse")
        }
        XCTAssertEqual(segs.first?.key?.iv?.count, 16)
    }

    func testIVOnAnUnencryptedKeyLineIsIgnored() {
        XCTAssertNotNil(HLSParser.parse(keyedPlaylist(iv: "junk", method: "NONE"), baseURL: base))
    }

    // MARK: - Init maps and discontinuities

    func testSecondDistinctInitMapIsRefused() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="main-init.mp4"
        #EXTINF:6.0,
        main0.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="ad-init.mp4"
        #EXTINF:6.0,
        ad0.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("the playlist itself is well-formed")
        }
        XCTAssertEqual(segs.map(\.initMap?.url.lastPathComponent), ["main-init.mp4", "ad-init.mp4"])
        XCTAssertEqual(segs.map(\.discontinuity), [false, true])
        XCTAssertFalse(HLSParser.usesSingleInitMap(segs),
                       "decoding the ad against the main init corrupts it silently")
    }

    func testRepeatedIdenticalInitMapIsAccepted() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        a.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        b.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("must parse")
        }
        XCTAssertTrue(HLSParser.usesSingleInitMap(segs))
    }

    func testSameInitMapRestatedAfterAKeyRotationIsOneMap() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="k1.bin",IV=0x01
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        a.m4s
        #EXT-X-KEY:METHOD=AES-128,URI="k2.bin",IV=0x02
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        b.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("must parse")
        }
        XCTAssertNotEqual(segs[0].initMap?.key?.url, segs[1].initMap?.key?.url)
        XCTAssertTrue(HLSParser.usesSingleInitMap(segs), "the header's bytes are the same; only the key moved")
    }

    func testSegmentsWithAndWithoutAMapAreRefused() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        pre.ts
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        a.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("must parse")
        }
        XCTAssertFalse(HLSParser.usesSingleInitMap(segs), "TS and fMP4 can't share one file")
    }

    // MARK: - Disk full (silent#4)

    func testDiskFullIsRecognisedFromEveryLayer() {
        XCTAssertTrue(HLSEngine.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(HLSEngine.isDiskFull(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)))
        XCTAssertTrue(HLSEngine.isDiskFull(DownloadError.unknown(
            "HLS → MP4 conversion failed: av_interleaved_write_frame(): No space left on device")))
        XCTAssertFalse(HLSEngine.isDiskFull(DownloadError.unknown("HLS segment decryption failed")))
        guard case .diskFull = HLSEngine.failure(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), savePath: "/tmp/x.mp4") else {
            return XCTFail("ENOSPC must map to diskFull")
        }
    }

    // MARK: - Sub-resource screen (security#2)

    func testSubresourceOnAnInternalHostIsRefusedBeforeItIsFetched() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        https://sneaky.example/seg0.ts
        #EXT-X-ENDLIST
        """
        ScriptedURLProtocol.script { req in
            .init(status: 200, headers: [:], body: Data(playlist.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        let engine = HLSEngine(profile: .high, configuration: config)
        await engine.setSubresourceCheck { url, _ in url.host != "sneaky.example" }
        let task = DownloadTask(source: .hlsStream(base), name: "clip.mp4",
                                saveDirectory: FileManager.default.temporaryDirectory.path)
        let events = engine.events(for: task.id)
        await engine.add(task)
        var failure: DownloadError?
        for await event in events {
            if case .failed(let e) = event { failure = e; break }
            if case .finished = event { break }
        }
        XCTAssertEqual(failure, HLSEngine.internalSubresourceRefusal)
        XCTAssertFalse(ScriptedURLProtocol.requests.contains { $0.url?.host == "sneaky.example" },
                       "the refused host must never see a request")
        await engine.remove(task.id, deleteData: false)
    }

    func testScreenVerdictIsCachedPerHost() async {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let calls = Calls()
        let screen = SubresourceScreen(parent: base) { _, _ in calls.bump(); return true }
        for i in 0..<5 {
            _ = await screen.allows(URL(string: "https://cdn2.example.com/seg\(i).ts")!)
        }
        _ = await screen.allows(URL(string: "https://cdn3.example.com/seg.ts")!)
        XCTAssertEqual(calls.count, 2, "one resolution per host, not per segment")
    }

    func testDiscontinuitySequenceTagIsNotADiscontinuity() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-DISCONTINUITY-SEQUENCE:3
        #EXTINF:6.0,
        a.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("must parse")
        }
        XCTAssertEqual(segs.map(\.discontinuity), [false])
    }

    // MARK: - Assembly

    func testConcatenateTruncatesAStaleLongerDestination() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-hls-cat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = dir.appendingPathComponent("p0")
        try Data([1, 2, 3]).write(to: part)
        let dest = dir.appendingPathComponent("out.mp4")
        try Data(repeating: 9, count: 64).write(to: dest)

        try HLSEngine.concatenate([part], to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data([1, 2, 3]), "the old file's tail must not survive")
    }

    func testFFmpegRemuxIsConfinedToLocalProtocols() {
        let args = HLSEngine.remuxArguments(source: "/tmp/in.ts", destination: "/tmp/out.mp4")
        let whitelist = try? XCTUnwrap(args.firstIndex(of: "-protocol_whitelist"))
        let input = args.firstIndex(of: "-i")
        XCTAssertNotNil(whitelist)
        XCTAssertEqual(whitelist.map { args[$0 + 1] }, "file,crypto,data")
        if let whitelist, let input { XCTAssertLessThan(whitelist, input, "input options must precede -i") }
    }
}
