import XCTest
@testable import GoelCore

final class RemotePortalHardeningTests: XCTestCase {

    private func request(_ raw: String) -> RemoteRequest { RemoteRequest(raw: Data(raw.utf8)) }

    // MARK: SEC-7 Host allowlist

    func testHostPolicyTable() {
        let security = RemotePortalSecurity(allowedHosts: ["goel.example.com", "*.corp.example"])
        let table: [(String?, Bool)] = [
            (nil, true),
            ("127.0.0.1:8899", true),
            ("[::1]:8899", true),
            ("192.168.1.20:8899", true),
            ("100.101.102.103", true),
            ("localhost:8899", true),
            ("app.localhost", true),
            ("macbook.local:8899", true),
            ("nas", true),
            ("goel.example.com", true),
            ("GOEL.example.com.:443", true),
            ("portal.corp.example", true),
            ("evil.example:8899", false),
            ("127.0.0.1.nip.io:8899", false),
            ("corp.example.evil.test", false),
            ("a:b:c", false),
        ]
        for (host, expected) in table {
            XCTAssertEqual(RemoteHostPolicy.allows(hostHeader: host, client: "192.168.1.50",
                                                   security: security), expected, host ?? "nil")
        }
    }

    func testTrustedProxyPeerMayUseAnyHost() {
        let security = RemotePortalSecurity(
            sso: TrustedIdentityHeaderPolicy(trustedProxies: ["10.0.0.0/8"]), allowedHosts: [])
        XCTAssertTrue(RemoteHostPolicy.allows(hostHeader: "goel.public.example", client: "10.1.2.3",
                                              security: security))
        XCTAssertFalse(RemoteHostPolicy.allows(hostHeader: "goel.public.example", client: "192.168.0.9",
                                               security: security))
    }

    func testAllowedHostsParseFromACommaList() {
        XCTAssertEqual(RemoteHostPolicy.parseList(" A.example , *.b.example,, "),
                       ["a.example", "*.b.example"])
    }

    // MARK: SEC-6 Secure cookie / token scope

    func testSessionCookieIsSecureOnlyWhenAsked() async {
        let store = RemoteSessionStore()
        let plain = await store.issueSession()
        let secure = await store.issueSession(secure: true)
        XCTAssertFalse(plain.contains("Secure"))
        XCTAssertTrue(secure.hasSuffix("; Secure"))
        XCTAssertTrue(secure.contains("HttpOnly; SameSite=Strict"))
    }

    func testSecureCookieDecision() {
        let forwarded = request("GET / HTTP/1.1\r\nX-Forwarded-Proto: https\r\n\r\n")
        let proxied = RemotePortalSecurity(sso: TrustedIdentityHeaderPolicy(trustedProxies: ["127.0.0.1"]))
        XCTAssertTrue(RemoteAuthService.wantsSecureCookie(forwarded, client: "127.0.0.1", security: proxied))
        XCTAssertFalse(RemoteAuthService.wantsSecureCookie(forwarded, client: "192.168.1.9", security: proxied),
                       "an untrusted peer cannot claim TLS")
        XCTAssertFalse(RemoteAuthService.wantsSecureCookie(request("GET / HTTP/1.1\r\n\r\n"),
                                                           client: "127.0.0.1", security: proxied))
        XCTAssertTrue(RemoteAuthService.wantsSecureCookie(request("GET / HTTP/1.1\r\n\r\n"),
                                                          client: "", security: RemotePortalSecurity(tlsEnabled: true)))
    }

    func testQueryTokenIsHonouredOnlyOnTheLandingPageAndStream() {
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        XCTAssertTrue(router.authorize(request("GET /?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(router.authorize(request("GET /stream?id=x&token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertFalse(router.authorize(request("GET /api/tasks?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertFalse(router.authorize(request("POST /api/pause-all?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertFalse(router.authorize(request("GET /api/events?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(router.authorize(request("GET /api/tasks HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n")))
        XCTAssertFalse(RemoteAuthService.tokenAuthed(request("GET /api/tasks?token=secret HTTP/1.1\r\n\r\n"),
                                                     token: "secret"))
    }

    // MARK: SEC-5 redaction

    func testHTTPUserInfoIsStrippedAtParseAndOfferedAsAHeader() throws {
        let source = try XCTUnwrap(DownloadSource.parse("https://alice:p%40ss@files.example.com/f.zip"))
        XCTAssertEqual(source.locator, "https://files.example.com/f.zip")
        let parsed = try XCTUnwrap(DownloadSource.parseWithCredentials("https://alice:p%40ss@files.example.com/f.zip"))
        XCTAssertEqual(parsed.authorization, "Basic " + Data("alice:p@ss".utf8).base64EncodedString())
        XCTAssertNil(DownloadSource.parseWithCredentials("https://files.example.com/f.zip")?.authorization)
        let torrent = try XCTUnwrap(DownloadSource.parse("https://u:p@t.example/x.torrent"))
        XCTAssertEqual(torrent.locator, "https://t.example/x.torrent")
    }

    func testSignedQueriesAreRedactedForTheRemoteAPI() {
        XCTAssertEqual(DownloadSource.redacted(
            "https://b.s3.amazonaws.com/k.bin?X-Amz-Credential=AK&X-Amz-Signature=deadbeef"),
            "https://b.s3.amazonaws.com/k.bin")
        XCTAssertEqual(DownloadSource.redacted("https://e.example/a?sig=1&v=2"), "https://e.example/a")
        XCTAssertEqual(DownloadSource.redacted("https://e.example/a?page=2"), "https://e.example/a?page=2")
        XCTAssertEqual(DownloadSource.redacted("https://u:p@e.example/a"), "https://e.example/a")
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=x"
        XCTAssertEqual(DownloadSource.redacted(magnet), magnet)

        let task = DownloadTask(source: .url(URL(string: "https://e.example/f?token=SECRET")!),
                                name: "f", saveDirectory: "/tmp", status: .queued)
        let row = RemoteRouter.TaskRow(task)
        XCTAssertFalse(row.source.contains("SECRET"))
    }

    // MARK: PERF-7 SSE

    func testStreamableHintNeedsNoDisk() {
        let done = DownloadTask(source: .url(URL(string: "https://e/x.mp4")!), name: "x.mp4",
                                saveDirectory: "/nonexistent-dir", status: .completed)
        XCTAssertTrue(RemoteStreamService.isStreamableHint(done))
        let queued = DownloadTask(source: .url(URL(string: "https://e/x.mp4")!), name: "x.mp4",
                                  saveDirectory: "/tmp", status: .queued)
        XCTAssertFalse(RemoteStreamService.isStreamableHint(queued))
    }

    func testFrameCacheReusesUnchangedFramesAndPacerSkipsThem() {
        var task = DownloadTask(id: UUID(), source: .url(URL(string: "https://e/x.bin")!),
                                name: "x.bin", saveDirectory: "/tmp", status: .downloading)
        let cache = RemoteEventFrameCache()
        let first = cache.frame(for: [task])
        let second = cache.frame(for: [task])
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)

        var pacer = RemoteEventPacer()
        let t0 = Date()
        XCTAssertEqual(pacer.next(first, now: t0), .send(first!.data))
        XCTAssertEqual(pacer.next(second, now: t0.addingTimeInterval(1.5)), .skip)
        XCTAssertEqual(pacer.next(second, now: t0.addingTimeInterval(16)), .keepAlive)

        task.bytesDownloaded = 42
        let changed = cache.frame(for: [task])
        XCTAssertNotEqual(changed?.hash, first?.hash)
        XCTAssertEqual(pacer.next(changed, now: t0.addingTimeInterval(17)), .send(changed!.data))
    }

    // MARK: SEC-10 limits

    func testConnectionGateCapsPerPeerButNotLoopback() {
        let gate = RemoteConnectionGate(limit: 10, perClientLimit: 2)
        XCTAssertTrue(gate.tryAcquire(client: "192.168.1.5"))
        XCTAssertTrue(gate.tryAcquire(client: "192.168.1.5"))
        XCTAssertFalse(gate.tryAcquire(client: "192.168.1.5"))
        XCTAssertTrue(gate.tryAcquire(client: "192.168.1.6"))
        for _ in 0..<3 { XCTAssertTrue(gate.tryAcquire(client: "127.0.0.1")) }
        gate.release(client: "192.168.1.5")
        XCTAssertTrue(gate.tryAcquire(client: "192.168.1.5"))
        XCTAssertEqual(gate.openCount, 6)
        gate.release(client: "10.9.9.9")   // never acquired: must not erode the cap
        XCTAssertEqual(gate.openCount, 6)
    }

    func testOversizedHeaderBlockIsDetected() {
        let huge = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)
        XCTAssertTrue(RemoteRequest.headerTooLarge(huge))
        let ok = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertFalse(RemoteRequest.headerTooLarge(ok))
        XCTAssertEqual(RemoteRequest.headerEnd(ok), ok.count)
        XCTAssertEqual(RemoteRequest.headerEnd(ok.dropFirst(4)), ok.count - 4, "slices index from their start")
    }
}

final class GoelFormatTests: XCTestCase {

    func testBytesAreFinderStyleAndByteStringUsesThem() {
        let expected = ByteCountFormatter.string(fromByteCount: 1_500_000_000, countStyle: .file)
        XCTAssertEqual(GoelFormat.bytes(1_500_000_000), expected)
        XCTAssertEqual(Int64(1_500_000_000).byteString, expected)
        XCTAssertEqual(Int64(0).byteString, "—")
        XCTAssertEqual(Double(0.4).speedString, "—")
        XCTAssertEqual(Double(2_000_000).speedString, GoelFormat.bytes(2_000_000) + "/s")
        XCTAssertEqual(Double.infinity.speedString, "—")
    }

    func testManualDurationShape() {
        XCTAssertEqual(GoelFormat.manualDuration(5400), "1h 30m")
        XCTAssertEqual(GoelFormat.manualDuration(45), "45s")
        XCTAssertEqual(GoelFormat.manualDuration(0), "0s")
        XCTAssertEqual(GoelFormat.manualDuration(90_061), "1d 1h")
    }

    func testDurationIsNeverBlank() {
        XCTAssertFalse(GoelFormat.duration(0).isEmpty)
        XCTAssertFalse(GoelFormat.duration(5400).isEmpty)
        XCTAssertEqual(GoelFormat.duration(-1), "—")
        XCTAssertEqual(GoelFormat.duration(.nan), "—")
    }

    func testDownloadErrorMessagesGoThroughL10n() {
        XCTAssertEqual(DownloadError.httpStatus(403).message, "Server returned HTTP 403")
        XCTAssertEqual(DownloadError.network("reset").message, "Network error: reset")
        XCTAssertTrue(DownloadError.diskFull(needed: 2_000_000, available: 1_000_000).message
            .contains(GoelFormat.bytes(2_000_000)))
    }
}

final class PathSafetyScalarTests: XCTestCase {

    func testBidiControlsAndBackslashAreNeutralised() {
        XCTAssertEqual(PathSafety.sanitizedName("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(PathSafety.sanitizedName("a\u{2066}b\u{2069}.txt"), "ab.txt")
        XCTAssertEqual(PathSafety.sanitizedName("a\u{0}b\u{7}.txt"), "ab.txt")
        XCTAssertEqual(PathSafety.sanitizedName("..\\..\\x.bat"), "download")
        XCTAssertEqual(PathSafety.sanitizedName("dir\\file.txt"), "dir_file.txt")
        XCTAssertEqual(PathSafety.sanitizedName("family👨‍👩‍👧.png"), "family👨‍👩‍👧.png",
                       "ZWJ emoji sequences must survive")
    }
}
