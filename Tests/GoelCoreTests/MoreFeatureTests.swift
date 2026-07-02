import XCTest
import Foundation
@testable import GoelCore

/// Tests for the second feature batch: batch patterns, published-checksum
/// discovery, and (as later waves land) history, scheduling, mirrors, metalink.
final class MoreFeatureTests: XCTestCase {

    // MARK: Batch pattern expansion

    func testNumericRangeExpandsWithPadding() {
        let out = BatchExpander.expand("https://x.example/file[01-03].zip")
        XCTAssertEqual(out, [
            "https://x.example/file01.zip",
            "https://x.example/file02.zip",
            "https://x.example/file03.zip",
        ])
    }

    func testNumericRangeWithoutPadding() {
        let out = BatchExpander.expand("https://x.example/part[9-11]")
        XCTAssertEqual(out, ["https://x.example/part9",
                             "https://x.example/part10",
                             "https://x.example/part11"])
    }

    func testAlternationAndCartesianProduct() {
        let out = BatchExpander.expand("https://x.example/v[1-2]/img.{png,jpg}")
        XCTAssertEqual(Set(out), [
            "https://x.example/v1/img.png", "https://x.example/v1/img.jpg",
            "https://x.example/v2/img.png", "https://x.example/v2/img.jpg",
        ])
        XCTAssertEqual(out.count, 4)
    }

    func testOverCapRangeReturnsLineVerbatim() {
        let line = "https://x.example/file[1-999999].zip"
        XCTAssertEqual(BatchExpander.expand(line), [line])
    }

    func testCartesianOverCapReturnsLineVerbatim() {
        // 400 × 400 crosses the cap even though each range alone is fine.
        let line = "https://x.example/[1-400]/[1-400]"
        XCTAssertEqual(BatchExpander.expand(line), [line])
    }

    func testMagnetAndIPv6PassThroughUntouched() {
        let magnet = "magnet:?xt=urn:btih:abc&dn=file{a,b}"
        XCTAssertEqual(BatchExpander.expand(magnet), [magnet])
        let v6 = "http://[::1]:8080/file.zip"
        XCTAssertEqual(BatchExpander.expand(v6), [v6])
    }

    func testPlainLineIsUnchanged() {
        XCTAssertEqual(BatchExpander.expand("https://x.example/a.zip"),
                       ["https://x.example/a.zip"])
    }

    // MARK: Published checksum discovery

    private func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x.example/f")!,
                        statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }

    func testDigestHeaderSHA256Decodes() {
        // sha-256 of empty input, base64: 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        let http = response(["Digest": "sha-256=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="])
        let checksum = HTTPEngine.checksum(fromHeaders: http)
        XCTAssertEqual(checksum?.algorithm, .sha256)
        XCTAssertEqual(checksum?.value,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testReprDigestStructuredFieldDecodes() {
        let http = response(["Repr-Digest": "sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:"])
        XCTAssertEqual(HTTPEngine.checksum(fromHeaders: http)?.algorithm, .sha256)
    }

    func testContentMD5Decodes() {
        // md5 of empty input, base64: 1B2M2Y8AsgTpgAmY7PhCfg==
        let http = response(["Content-MD5": "1B2M2Y8AsgTpgAmY7PhCfg=="])
        let checksum = HTTPEngine.checksum(fromHeaders: http)
        XCTAssertEqual(checksum?.algorithm, .md5)
        XCTAssertEqual(checksum?.value, "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testMalformedDigestIsRejected() {
        XCTAssertNil(HTTPEngine.checksum(fromHeaders: response(["Digest": "sha-256=nonsense!!!"])))
        // Wrong decoded length for the declared algorithm must not slip through.
        XCTAssertNil(HTTPEngine.checksum(fromHeaders: response(["Digest": "sha-256=AAAA"])))
        XCTAssertNil(HTTPEngine.checksum(fromHeaders: response([:])))
    }

    func testSidecarBodyParsing() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(HTTPEngine.checksum(inSidecarBody: "\(hex)  file.zip\n")?.value, hex)
        XCTAssertEqual(HTTPEngine.checksum(inSidecarBody: hex)?.algorithm, .sha256)
        XCTAssertNil(HTTPEngine.checksum(inSidecarBody: "not a hash at all"))
        XCTAssertNil(HTTPEngine.checksum(inSidecarBody: ""))
    }

    // MARK: Download history

    func testHistoryRoundTripDeleteAndClear() throws {
        let store = try PersistenceStore()
        let entry = HistoryEntry(id: UUID(), name: "a.zip",
                                 locator: "https://x.example/a.zip", kind: .http,
                                 totalBytes: 5, savePath: "/tmp/a.zip",
                                 completedAt: Date())
        try store.saveHistoryEntry(entry)
        let loaded = try store.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "a.zip")
        XCTAssertEqual(loaded.first?.locator, "https://x.example/a.zip")

        try store.deleteHistoryEntry(entry.id)
        XCTAssertTrue(try store.loadHistory().isEmpty)

        try store.saveHistoryEntry(entry)
        try store.clearHistory()
        XCTAssertTrue(try store.loadHistory().isEmpty)
    }

    func testHistoryOrderedNewestFirstAndLimited() throws {
        let store = try PersistenceStore()
        for i in 0..<5 {
            try store.saveHistoryEntry(HistoryEntry(
                id: UUID(), name: "f\(i)", locator: "https://x.example/f\(i)",
                kind: .http, totalBytes: nil, savePath: "/tmp/f\(i)",
                completedAt: Date(timeIntervalSinceReferenceDate: Double(i * 100))))
        }
        let newestFirst = try store.loadHistory(limit: 3)
        XCTAssertEqual(newestFirst.map(\.name), ["f4", "f3", "f2"])
    }

    // MARK: Per-task scheduled starts

    func testScheduledAddIsHeldPaused() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: nil)
        let source = DownloadSource.parse("https://example.com/later.bin")!
        let task = await manager.add(source: source,
                                     scheduledAt: Date().addingTimeInterval(3600))
        XCTAssertEqual(task.status, .paused)
        XCTAssertNotNil(task.scheduledAt)
        // The optimistic scheduler must not promote it.
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await manager.task(task.id)
        XCTAssertEqual(after?.status, .paused)
    }

    func testManualResumeClearsScheduledStart() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: nil)
        let source = DownloadSource.parse("https://example.com/later2.bin")!
        let task = await manager.add(source: source,
                                     scheduledAt: Date().addingTimeInterval(3600))
        await manager.resume(task.id)
        let after = await manager.task(task.id)
        XCTAssertNil(after?.scheduledAt)
        XCTAssertNotEqual(after?.status, .paused)
    }

    func testSetScheduledStartOnQueuedTaskHoldsIt() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: nil)
        let source = DownloadSource.parse("https://example.com/hold.bin")!
        let task = await manager.add(source: source)
        await manager.setScheduledStart(Date().addingTimeInterval(3600), task: task.id)
        let held = await manager.task(task.id)
        XCTAssertEqual(held?.status, .paused)
        XCTAssertNotNil(held?.scheduledAt)
        // Clearing the schedule leaves it paused (the user starts it).
        await manager.setScheduledStart(nil, task: task.id)
        let cleared = await manager.task(task.id)
        XCTAssertEqual(cleared?.status, .paused)
        XCTAssertNil(cleared?.scheduledAt)
    }

    // MARK: Remote streaming

    func testByteRangeParsing() {
        // Plain range, clamped end, open end, suffix form, junk.
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=0-99", available: 1000)?.0, 0)
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=0-99", available: 1000)?.1, 99)
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=0-5000", available: 1000)?.1, 999)
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=200-", available: 1000)?.0, 200)
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=200-", available: 1000)?.1, 999)
        XCTAssertEqual(RemoteControlServer.parseByteRange("bytes=-100", available: 1000)?.0, 900)
        XCTAssertNil(RemoteControlServer.parseByteRange("bytes=2000-", available: 1000))
        XCTAssertNil(RemoteControlServer.parseByteRange("items=0-5", available: 1000))
        XCTAssertNil(RemoteControlServer.parseByteRange("bytes=abc-def", available: 1000))
    }

    func testStreamPlanGatesInFlightTasks() {
        let url = URL(string: "https://x.example/movie.mkv")!
        // Non-sequential in-flight: not streamable.
        var task = DownloadTask(source: .url(url), name: "movie.mkv", saveDirectory: "/tmp",
                                totalBytes: 100_000_000, bytesDownloaded: 50_000_000,
                                status: .downloading)
        XCTAssertNil(RemoteControlServer.streamPlan(for: task))
        // Sequential with a healthy prefix: streamable, margin held back.
        task.sequentialDownload = true
        let plan = RemoteControlServer.streamPlan(for: task)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan.map(\.availableBytes), 50_000_000 - 8 * 1024 * 1024)
        // Sequential but barely started (inside the margin): not yet.
        task.bytesDownloaded = 1_000_000
        XCTAssertNil(RemoteControlServer.streamPlan(for: task))
    }

    // MARK: Mirrors & Metalink

    func testMetalink4Parsing() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="ubuntu.iso">
            <size>4700000000</size>
            <hash type="sha-256">\(String(repeating: "ab", count: 32))</hash>
            <hash type="md5">\(String(repeating: "cd", count: 16))</hash>
            <url priority="1">https://mirror-a.example/ubuntu.iso</url>
            <url priority="2">https://mirror-b.example/ubuntu.iso</url>
            <url>ftp://old.example/ubuntu.iso</url>
          </file>
        </metalink>
        """
        let files = MetalinkParser.parse(Data(xml.utf8))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "ubuntu.iso")
        XCTAssertEqual(files.first?.size, 4_700_000_000)
        XCTAssertEqual(files.first?.urls.count, 2)   // ftp dropped
        XCTAssertEqual(files.first?.checksum?.algorithm, .sha256)   // strongest wins
    }

    func testMetalink3Parsing() {
        let xml = """
        <?xml version="1.0"?>
        <metalink version="3.0" xmlns="http://www.metalinker.org/">
          <files>
            <file name="tool.dmg">
              <size>1024</size>
              <verification><hash type="sha1">\(String(repeating: "ef", count: 20))</hash></verification>
              <resources>
                <url type="http">http://a.example/tool.dmg</url>
                <url type="http">http://b.example/tool.dmg</url>
              </resources>
            </file>
          </files>
        </metalink>
        """
        let files = MetalinkParser.parse(Data(xml.utf8))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.urls.count, 2)
        XCTAssertEqual(files.first?.checksum?.algorithm, .sha1)
    }

    func testMetalinkFileWithoutHTTPSourcesIsDropped() {
        let xml = """
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="x"><url>ftp://only.example/x</url></file>
        </metalink>
        """
        XCTAssertTrue(MetalinkParser.parse(Data(xml.utf8)).isEmpty)
    }

    func testSanitizedMirrorsFiltersAndCaps() {
        let primary = DownloadSource.parse("https://primary.example/f.zip")!
        let raw = ["https://primary.example/f.zip",       // primary itself — dropped
                   "file:///etc/passwd",                  // bad scheme — dropped
                   "https://a.example/f.zip",
                   "https://a.example/f.zip",             // duplicate — dropped
                   "  http://b.example/f.zip  "]          // trimmed, kept
        let clean = DownloadManager.sanitizedMirrors(raw, primary: primary)
        XCTAssertEqual(clean, ["https://a.example/f.zip", "http://b.example/f.zip"])
        // Cap at 10.
        let many = (0..<40).map { "https://m\($0).example/f" }
        XCTAssertEqual(DownloadManager.sanitizedMirrors(many, primary: primary)?.count, 10)
        XCTAssertNil(DownloadManager.sanitizedMirrors([], primary: primary))
        XCTAssertNil(DownloadManager.sanitizedMirrors(["javascript:alert(1)"], primary: primary))
    }

    func testMirrorPoolRoundRobinAndDemotion() async {
        let primary = URL(string: "https://p.example/f")!
        let m1 = URL(string: "https://m1.example/f")!
        let m2 = URL(string: "https://m2.example/f")!
        let pool = SegmentedTransfer.MirrorPool(primary: primary, mirrors: [m1, m2])

        // First attempts spread segments across the pool round-robin.
        let s0 = await pool.url(segment: 0, attempt: 1)
        let s1 = await pool.url(segment: 1, attempt: 1)
        let s2 = await pool.url(segment: 2, attempt: 1)
        XCTAssertEqual([s0, s1, s2], [primary, m1, m2])

        // Demoting a mirror removes it from rotation…
        await pool.demote(m1)
        let healthy = await pool.url(segment: 1, attempt: 1)
        XCTAssertNotEqual(healthy, m1)

        // …and demoting everything resets the slate (pool never goes empty).
        await pool.demote(primary)
        await pool.demote(m2)
        let revived = await pool.url(segment: 0, attempt: 1)
        XCTAssertEqual(revived, primary)
    }

    // MARK: FTP routing

    func testFTPURLsParseAndDeriveFTPKind() {
        let ftp = DownloadSource.parse("ftp://mirror.example/pub/file.iso")
        XCTAssertNotNil(ftp)
        XCTAssertEqual(ftp?.kind, .ftp)
        let ftps = DownloadSource.parse("ftps://secure.example/file.bin")
        XCTAssertEqual(ftps?.kind, .ftp)
        // http stays http; the allowlist still rejects everything else.
        XCTAssertEqual(DownloadSource.parse("https://x.example/f.zip")?.kind, .http)
        XCTAssertNil(DownloadSource.parse("file:///etc/passwd"))
        XCTAssertNil(DownloadSource.parse("sftp://host/file"))
    }

    func testFTPTorrentSuffixStillRequiresHTTP() {
        // An ftp URL ending in .torrent must not slip into the torrent-file
        // fetch path (which downloads and parses the file over HTTP).
        let source = DownloadSource.parse("ftp://host.example/file.torrent")
        if case .torrentFile = source {
            XCTFail("ftp .torrent URL must not route to the torrent-file fetcher")
        }
    }

    func testTaskWithScheduledAtDecodesFromOldBlob() throws {
        // A pre-feature task blob (no scheduledAt key) must still decode.
        let old = DownloadTask(source: .url(URL(string: "https://x.example/f")!),
                               name: "f", saveDirectory: "/tmp")
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "scheduledAt")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: data)
        XCTAssertNil(decoded.scheduledAt)
    }
}
