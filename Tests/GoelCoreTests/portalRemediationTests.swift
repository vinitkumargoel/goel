import XCTest
#if !os(Linux)
import Network
#endif
@testable import GoelCore

private final class FolderRefusingBackend: RemoteBackend, @unchecked Sendable {
    private(set) var added: [DownloadSource] = []
    private(set) var folders: [String?] = []

    func taskSnapshot() async -> [DownloadTask] { [] }
    func task(_ id: UUID) async -> DownloadTask? { nil }
    func pauseAll() async {}
    func resumeAll() async {}
    func pause(_ id: UUID) async {}
    func resume(_ id: UUID) async {}
    func retry(_ id: UUID) async {}
    func remove(_ id: UUID, deleteData: Bool) async {}
    func forceRecheck(_ id: UUID) async {}
    func setSequential(_ sequential: Bool, task id: UUID) async {}
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {}
    func remoteAdd(source: DownloadSource) async { added.append(source) }
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async {
        added.append(source)
        folders.append(saveDirectory)
    }
    func history(limit: Int) async -> [HistoryEntry] { [] }
    func removeHistoryEntry(_ id: UUID) async {}
    func clearHistory() async {}
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool { false }
}

final class PortalRemediationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkGuard.hostResolver = PlaceholderHosts.resolver
    }

    override func tearDown() {
        NetworkGuard.useSystemHostResolver()
        super.tearDown()
    }

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    private func request(_ raw: String) -> RemoteRequest {
        RemoteRequest(raw: Data(raw.utf8))
    }

    private func addRequest(_ body: String, headers: String = "") -> RemoteRequest {
        request("POST /api/add?token=secret HTTP/1.1\r\nContent-Type: application/json\r\n"
                + headers + "\r\n" + body)
    }

    /// SSRF: loopback, cloud metadata, and the integer/octal spellings of 127.0.0.1 must never reach the backend.
    func testAddRefusesInternalNetworkTargets() async throws {
        let internalTargets = [
            "http://127.0.0.1:9/x.bin",
            "http://localhost:8080/x.bin",
            "http://169.254.169.254/latest/meta-data/",
            "http://2130706433/x.bin",
            "http://0177.0.0.1/x.bin",
            "http://[::1]:9/x.bin",
        ]
        for target in internalTargets {
            let backend = FakeRemoteBackend()
            let router = RemoteRouter(backend: backend, token: "secret")
            let out = str(await router.handle(addRequest(#"{"url":"\#(target)"}"#)))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), "\(target) should be refused — got: \(out)")
            XCTAssertTrue(backend.added.isEmpty, "\(target) must never reach the backend")
        }
    }

    func testAddStillAcceptsPublicLANAndMagnetSources() async throws {
        let allowed = [
            "https://e/x.bin",
            "http://192.168.1.10/x.iso",
            "sftp://nas/x.zip",
            "magnet:?xt=urn:btih:0000000000000000000000000000000000000000",
        ]
        for target in allowed {
            let backend = FakeRemoteBackend()
            let router = RemoteRouter(backend: backend, token: "secret")
            let out = str(await router.handle(addRequest(#"{"url":"\#(target)"}"#)))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), "\(target) should be accepted — got: \(out)")
            XCTAssertEqual(backend.added.count, 1, "\(target) should have been added")
        }
    }

    func testAddReportsRefusedCountForAMixedBatch() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let body = #"{"url":"https://e/ok.bin\nhttp://127.0.0.1/secret"}"#
        let out = str(await router.handle(addRequest(body)))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(out.contains("\"added\":1"), out)
        XCTAssertTrue(out.contains("\"refused\":1"), out)
        XCTAssertEqual(backend.added.count, 1)
    }

    func testRemoteAddTargetGuardClassifiesHosts() {
        func url(_ text: String) -> URL { URL(string: text)! }
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("http://127.0.0.1/x")))
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("http://0.0.0.0/x")))
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("http://169.254.169.254/x")))
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("file:///etc/passwd")))
        XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(url("https://example.com/x")))
        XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(url("ftp://ftp.example.com/x")))
        // A real hostname that merely starts with a zero is not an octal literal.
        XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(url("http://0x-mirror.example.com/x")))
    }

    func testAddRefusesAnUnwritableSaveFolder() async {
        let backend = FolderRefusingBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let body = #"{"url":"https://e/x.bin","folder":"/etc/cron.d"}"#
        let out = str(await router.handle(addRequest(body)))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), out)
        XCTAssertTrue(backend.added.isEmpty, "a refused folder must not add anything")
    }

    func testAddWithNoFolderIsUnaffectedByTheWritabilityCheck() async {
        let backend = FolderRefusingBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(addRequest(#"{"url":"https://e/x.bin"}"#)))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertEqual(backend.added.count, 1)
    }

    private struct UnencodableRow: Encodable {
        var progress: Double
    }

    func testJSONEncodeFailureIsAServerErrorNotAnEmptyBody() {
        let out = str(RemoteRouter.json(UnencodableRow(progress: .nan)))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 500"), out)
        XCTAssertFalse(out.contains("null"), "a wiped list must not be served as success")
        XCTAssertTrue(str(RemoteRouter.json(UnencodableRow(progress: 0.5))).hasPrefix("HTTP/1.1 200 OK"))
    }

    func testEventFrameIsNilRatherThanAnEmptyListWhenEncodingFails() {
        var task = DownloadTask(id: UUID(), source: .url(URL(string: "https://e/x.bin")!),
                                name: "x.bin", saveDirectory: "/tmp", status: .downloading)
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        XCTAssertNotNil(router.eventFrame(for: [task]))
        task.downloadSpeed = .infinity
        XCTAssertNil(router.eventFrame(for: [task]),
                     "a non-finite speed must skip the tick, not blank the client's list")
    }

    func testForeignOriginPOSTIsRefused() async {
        let backend = FakeRemoteBackend()
        let config = RemoteRouter.Config(token: "", requireAuth: false)
        let router = RemoteRouter(backend: backend, config: config)
        let out = str(await router.handle(request(
            "POST /api/pause-all HTTP/1.1\r\nHost: 127.0.0.1:8899\r\nOrigin: http://evil.test\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), out)
        XCTAssertFalse(backend.pausedAll, "a cross-site POST must not reach the backend")
    }

    func testSameOriginPOSTIsAllowed() async {
        let backend = FakeRemoteBackend()
        let config = RemoteRouter.Config(token: "", requireAuth: false)
        let router = RemoteRouter(backend: backend, config: config)
        let out = str(await router.handle(request(
            "POST /api/pause-all HTTP/1.1\r\nHost: 127.0.0.1:8899\r\nOrigin: http://127.0.0.1:8899\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertTrue(backend.pausedAll)
    }

    /// No `Origin` means no browser — `curl`, the extension, a script — which were never the CSRF threat.
    func testOriginlessPOSTIsAllowed() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request("POST /api/pause-all?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertTrue(backend.pausedAll)
    }

    func testForwardedHostCountsAsTheAuthority() async {
        let backend = FakeRemoteBackend()
        let config = RemoteRouter.Config(token: "", requireAuth: false)
        let router = RemoteRouter(backend: backend, config: config)
        let out = str(await router.handle(request(
            "POST /api/pause-all HTTP/1.1\r\nHost: 127.0.0.1:8899\r\n"
            + "X-Forwarded-Host: goel.example.com\r\nOrigin: https://goel.example.com\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertTrue(backend.pausedAll)
    }

    func testOriginMatchingIgnoresSchemeButNotPort() {
        XCTAssertTrue(RemoteRouter.originMatchesHost("https://box.local:8899", host: "box.local:8899"))
        XCTAssertTrue(RemoteRouter.originMatchesHost("http://Box.Local", host: "box.local"))
        XCTAssertFalse(RemoteRouter.originMatchesHost("http://127.0.0.1:9999", host: "127.0.0.1:8899"))
        XCTAssertFalse(RemoteRouter.originMatchesHost("null", host: "127.0.0.1:8899"))
        XCTAssertFalse(RemoteRouter.originMatchesHost("http://127.0.0.1:8899", host: nil))
    }

    func testTokenDeepLinkOnlyPromotesTheRootPageLoad() {
        func promotes(_ raw: String, sessionAuthed: Bool = false, tokenAuthed: Bool = true,
                      requireAuth: Bool = true) -> Bool {
            RemoteAuthService.shouldPromoteTokenToSession(
                request(raw), requireAuth: requireAuth,
                sessionAuthed: sessionAuthed, tokenAuthed: tokenAuthed)
        }
        XCTAssertTrue(promotes("GET / HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(promotes("GET / HTTP/1.1\r\n\r\n", sessionAuthed: true))
        XCTAssertFalse(promotes("GET / HTTP/1.1\r\n\r\n", tokenAuthed: false))
        XCTAssertFalse(promotes("GET / HTTP/1.1\r\n\r\n", requireAuth: false))
        XCTAssertFalse(promotes("GET /api/tasks HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(promotes("POST / HTTP/1.1\r\n\r\n"))
    }

    /// Asserts on the compiled bundle, so it may match only text that survives minification.
    func testPortalScriptScrubsTheTokenFromTheAddressBar() {
        XCTAssertTrue(PortalBundle.js.contains("history.replaceState"),
                      "the token must not linger in the address bar or in history")
    }

    /// `navigator.clipboard` is undefined over plain HTTP, which is the default LAN deployment.
    func testPortalScriptKeepsTheNonSecureContextCopyFallback() {
        XCTAssertTrue(PortalBundle.js.contains("execCommand"),
                      "a non-secure context needs a selection-copy fallback")
        XCTAssertTrue(PortalBundle.js.contains("writeText"),
                      "the secure-context path must still be preferred when available")
    }

    func testPageShellReferencesOnlyServableAssets() {
        let config = RemoteRouter.Config(token: "t", requireAuth: true, readOnly: false,
                                         theme: "nord", username: "admin")
        let shell = RemoteRouter.page(config: config)
        XCTAssertTrue(shell.contains(PortalBundle.jsPath), "the shell must load the bundle")
        XCTAssertTrue(shell.contains(PortalBundle.cssPath), "the shell must load the stylesheet")

        let login = RemoteRouter.loginPage(theme: "nord", error: nil)
        XCTAssertTrue(login.contains(PortalBundle.loginJSPath))
        XCTAssertTrue(login.contains(PortalBundle.loginCSSPath))

        for path in [PortalBundle.jsPath, PortalBundle.cssPath,
                     PortalBundle.loginJSPath, PortalBundle.loginCSSPath] {
            XCTAssertNotNil(RemoteRouter.staticAsset(path: path), "\(path) must be servable")
        }
    }

    /// The bundle is content-addressed: an unknown name must 404 rather than reach the filesystem.
    func testUnknownAssetIsNotFoundAndNeverTouchesTheFilesystem() {
        for path in ["/assets/nope.js", "/assets/../../etc/passwd", "/assets/"] {
            let data = RemoteRouter.staticAsset(path: path)
            let head = String(decoding: data ?? Data(), as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 404"), "\(path) must 404, got: \(head.prefix(40))")
        }
    }

    /// The portal renders off-machine names and tracker hosts, so inline script must stay forbidden.
    func testContentSecurityPolicyForbidsInlineScript() {
        let head = String(decoding: RemoteRouter.notFound(), as: UTF8.self)
        XCTAssertTrue(head.contains("script-src 'self'"), "script must come from /assets/ only")
        XCTAssertFalse(head.contains("'unsafe-inline'"), "inline execution must not be allowed")
    }

    func testAssetsAreImmutablyCachedAndPagesAreNot() {
        let asset = String(decoding: RemoteRouter.staticAsset(path: PortalBundle.jsPath) ?? Data(),
                           as: UTF8.self)
        XCTAssertTrue(asset.contains("Cache-Control: public, max-age=31536000, immutable"))
        XCTAssertFalse(asset.contains("Cache-Control: no-store"),
                       "an asset must carry exactly one Cache-Control header")

        let page = String(decoding: RemoteRouter.notFound(), as: UTF8.self)
        XCTAssertTrue(page.contains("Cache-Control: no-store"))
    }

    func testLogoutReportsWhetherASessionWasActuallyDropped() async throws {
        let store = RemoteSessionStore()
        await store.configure(username: "admin", passwordHash: PortalTestCredentials.hash,
                              sessionMinutes: 120)
        let noCookie = await store.handleLogout(request("POST /logout HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(noCookie.droppedSession,
                       "a logout that dropped nothing must not cost every client its stream")

        let body = #"{"username":"admin","password":"\#(PortalTestCredentials.password)"}"#
        let login = await store.handleLogin(request(
            "POST /login HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body))
        let sid = try XCTUnwrap(sessionCookie(in: login), "the login should have minted a session")
        let signOut = await store.handleLogout(request(
            "POST /logout HTTP/1.1\r\nCookie: goel_session=\(sid)\r\n\r\n"))
        XCTAssertTrue(signOut.droppedSession, "a real sign-out must be reported as one")
    }

    private func sessionCookie(in response: Data) -> String? {
        for line in str(response).components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("set-cookie:"),
                  let range = line.range(of: "goel_session=") else { continue }
            let value = line[range.upperBound...].prefix { $0 != ";" }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private func portalSettings(port: Int) -> AppSettings {
        var s = AppSettings()
        s.remoteAccessEnabled = true
        s.remotePort = port
        s.remoteAllowLAN = false
        s.remoteToken = "t"
        s.remoteRequireAuth = true
        s.remoteUsername = "admin"
        s.remotePasswordHash = PortalTestCredentials.hash
        s.remoteSessionMinutes = 120
        return s
    }

    func testOutOfRangePortIsRefusedAndReported() async {
        let manager = DownloadManager()
        let access = RemoteAccess()
        for port in [0, -1, 70000] {
            await access.apply(settings: portalSettings(port: port), backend: manager)
            let running = await access.isRunning
            XCTAssertFalse(running, "port \(port) must not bind an unpredictable ephemeral port")
            let failure = await access.lastStartFailure
            XCTAssertEqual(failure, .portUnavailable(port))
        }
        await access.stop()
        let cleared = await access.lastStartFailure
        XCTAssertNil(cleared, "a deliberate stop is not a failure")
    }

    /// The portal must refuse to start rather than serve cleartext; Linux reports `tlsUnsupported` instead.
    func testUnusableTLSIdentityIsReportedThroughRemoteAccess() async {
        let manager = DownloadManager()
        let access = RemoteAccess()
        var settings = portalSettings(port: Int(LoopbackPort.reserve()))
        settings.remoteTLSEnabled = true
        settings.remoteTLSIdentityPath = NSTemporaryDirectory() + "goel-no-such-identity.p12"
        await access.apply(settings: settings, backend: manager)

        let running = await access.isRunning
        XCTAssertFalse(running)
        let failure = await access.lastStartFailure
        XCTAssertNotNil(failure, "a refused start must be reportable, not just logged")
        XCTAssertTrue(failure?.message.contains("unencrypted") == true)
        #if !os(Linux)
        XCTAssertEqual(failure, .tlsIdentityUnavailable(path: settings.remoteTLSIdentityPath))
        #endif
        await access.stop()
    }

    /// Asserts on the reason, not the outcome: a restricted environment may still refuse the bind.
    func testAValidPortIsNeverReportedAsOutOfRange() async {
        let manager = DownloadManager()
        let access = RemoteAccess()
        let port = Int(LoopbackPort.reserve())
        await access.apply(settings: portalSettings(port: port), backend: manager)
        let failure = await access.lastStartFailure
        XCTAssertNotEqual(failure, .portUnavailable(port))
        await access.stop()
    }
}

#if !os(Linux)
final class PortalShellRemediationTests: XCTestCase {

    private func send(_ request: String, port: UInt16) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .ipv4(.loopback),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = DispatchQueue(label: "portal-probe.\(port)")
            var finished = false
            func finish(_ value: String?) {
                done.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            finish(data.map { String(decoding: $0, as: UTF8.self) })
                        }
                    })
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            done.asyncAfter(deadline: .now() + 1.0) { finish(nil) }
            conn.start(queue: done)
        }
    }

    private func waitUntilServing(port: UInt16) async throws {
        for _ in 0..<50 {
            if let head = await send("GET /api/config?token=t HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
                                     port: port), head.contains("HTTP/1.1") {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("the portal never came up on this machine")
    }

    /// `/logout` ahead of the auth gate let an anonymous `curl` drop the session and kill every live stream.
    func testUnauthenticatedLogoutIsRefused() async throws {
        let backend = PortalProbeBackend()
        let server = RemoteControlServer(manager: backend)
        let port = LoopbackPort.reserve()
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t", requireAuth: true,
                                                       username: "admin"),
                           passwordHash: PortalTestCredentials.hash, sessionMinutes: 120)
        guard await server.boundState() != nil else {
            throw XCTSkip("could not bind a loopback port in this environment")
        }
        defer { Task { await server.stop() } }
        try await waitUntilServing(port: port)

        let getHead = await send("GET /logout HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
                                 port: port)
        let get = try XCTUnwrap(getHead)
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 303"), "an anonymous GET /logout must bounce to login — got: \(get)")

        let postHead = await send("POST /logout HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
                                  port: port)
        let post = try XCTUnwrap(postHead)
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 401"), "an anonymous POST /logout must be refused — got: \(post)")
        XCTAssertFalse(post.contains("{\"ok\":true}"))
    }

    /// `GET /?token=…` must hand back a session cookie: everything the page does next carries no token.
    func testTokenDeepLinkIssuesASessionCookie() async throws {
        let backend = PortalProbeBackend()
        let server = RemoteControlServer(manager: backend)
        let port = LoopbackPort.reserve()
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t", requireAuth: true,
                                                       username: "admin"),
                           passwordHash: PortalTestCredentials.hash, sessionMinutes: 120)
        guard await server.boundState() != nil else {
            throw XCTSkip("could not bind a loopback port in this environment")
        }
        defer { Task { await server.stop() } }
        try await waitUntilServing(port: port)

        let landingHead = await send(
            "GET /?token=t HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", port: port)
        let landing = try XCTUnwrap(landingHead)
        XCTAssertTrue(landing.hasPrefix("HTTP/1.1 200 OK"), landing)
        XCTAssertTrue(landing.contains("Set-Cookie: goel_session="),
                      "a token deep-link must become a session, or the page's own fetches all 401")

        let sid = try XCTUnwrap(landing.components(separatedBy: "goel_session=").dropFirst().first?
            .prefix { $0 != ";" }.description)
        let reloadHead = await send(
            "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: goel_session=\(sid)\r\nConnection: close\r\n\r\n",
            port: port)
        let reload = try XCTUnwrap(reloadHead)
        XCTAssertTrue(reload.hasPrefix("HTTP/1.1 200 OK"),
                      "the issued session must survive a reload — got: \(reload)")
    }
}

/// Must be held strongly by the tests: ``RemoteControlServer`` keeps its manager weakly.
private final class PortalProbeBackend: RemoteBackend, @unchecked Sendable {
    func taskSnapshot() async -> [DownloadTask] { [] }
    func task(_ id: UUID) async -> DownloadTask? { nil }
    func pauseAll() async {}
    func resumeAll() async {}
    func pause(_ id: UUID) async {}
    func resume(_ id: UUID) async {}
    func retry(_ id: UUID) async {}
    func remove(_ id: UUID, deleteData: Bool) async {}
    func forceRecheck(_ id: UUID) async {}
    func setSequential(_ sequential: Bool, task id: UUID) async {}
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {}
    func remoteAdd(source: DownloadSource) async {}
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async {}
    func history(limit: Int) async -> [HistoryEntry] { [] }
    func removeHistoryEntry(_ id: UUID) async {}
    func clearHistory() async {}
}
#endif
