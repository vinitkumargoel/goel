#if !os(Linux)
import Foundation
import Network
#if canImport(Security)
import Security
#endif

/// Remote-access server: embedded HTTP exposing the queue (web page + JSON API), token-authenticated,
/// loopback-only unless LAN is allowed. Just the I/O shell — all decisions live in pure ``RemoteRouter``.
public actor RemoteControlServer {

    private weak var manager: RemoteBackend?
    private var listener: NWListener?

    /// Bind parameters the live `listener` was created with. Only these two affect the socket, so other
    /// settings update in place — a rebind can't reclaim the port instantly and failed with EADDRINUSE.
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?
    /// TLS is part of the bind identity too — HTTP↔HTTPS or a swapped certificate changes the socket's
    /// protocol stack, so it can't be applied in place the way a theme or token can.
    private var boundTLS: String?

    /// The current routing config (token, requireAuth, readOnly, theme, username),
    /// snapshotted from settings on each (re)start.
    private var routerConfig = RemoteRouter.Config(token: "")
    /// The stored password hash used to verify logins (never leaves the server).
    private var passwordHash = ""
    /// Login throttling, header SSO and TLS — the hardening layer, all defaulting
    /// to the portal's historical behaviour.
    private var security = RemotePortalSecurity()

    /// Shared session/login state (cookie map, lockout, KDF concurrency).
    private let sessionStore = RemoteSessionStore()

    public init(manager: RemoteBackend) {
        self.manager = manager
    }

    /// Live connections, capped so idle clients can't exhaust descriptors. The identifier set makes
    /// teardown exactly-once — idle timeout and receive completion race, and a double decrement erodes the cap.
    private var openConnections = 0
    private var liveConnections = Set<ObjectIdentifier>()
    private static let maxConnections = 32
    private static let receiveTimeout: UInt64 = 10 * 1_000_000_000
    /// Ceiling on a single request (headers + body) so a client can't grow the
    /// accumulation buffer without bound. Matches the Linux server.
    private static let maxRequestBytes = 2 * 1024 * 1024

    /// Live server-sent-event streams, capped separately (each holds a slot for
    /// its whole lifetime, unlike one-shot requests).
    private var sseConnections = 0
    private static let maxSSEConnections = 4

    /// Bumped on every start/stop so long-lived response loops (SSE, file
    /// streaming) notice a restart and wind down.
    private var generation = 0

    /// Why the last `start(...)` left nothing listening. Reasons live in ``RemotePortalStartFailure`` so
    /// both transports report the same set; this alias keeps the shell-scoped spelling callers use.
    public typealias StartFailure = RemotePortalStartFailure

    /// Set on each refusal in `start`, cleared the moment a listener is bound or the
    /// server is stopped. Read through ``lastStartFailure()``.
    private var startFailure: StartFailure?

    /// A router bound to the current backend + config, rebuilt per use (cheap).
    private var router: RemoteRouter { RemoteRouter(backend: manager, config: routerConfig) }

    /// Start/reconfigure listening (`allowLAN: false` = 127.0.0.1 only); credential changes invalidate
    /// sessions. Called on every settings change, but rebinds only on port/LAN change — else EADDRINUSE.
    public func start(port: UInt16, allowLAN: Bool, config: RemoteRouter.Config,
                      passwordHash: String, sessionMinutes: Int,
                      security: RemotePortalSecurity = RemotePortalSecurity()) async {
        let credentialsChanged = config.username != routerConfig.username
            || config.requireAuth != routerConfig.requireAuth
            || config.token != routerConfig.token
            || passwordHash != self.passwordHash
        if credentialsChanged {
            // Any credential change (token rotation included) logs everyone out: bump the generation so
            // already-open SSE/file-stream loops re-authenticate, else a leaked token keeps flowing.
            generation += 1
        }
        // Live config — applied whether or not we rebind, so a password / theme /
        // read-only / token change takes effect on the existing socket immediately.
        self.routerConfig = config
        self.passwordHash = passwordHash
        self.security = security
        // Single hop: rotate credentials and drop sessions together, so no login
        // can slip through this actor's suspension holding stale credentials.
        await sessionStore.configure(username: config.username, passwordHash: passwordHash,
                                     sessionMinutes: sessionMinutes,
                                     invalidatingSessions: credentialsChanged)
        await sessionStore.configure(throttle: security.throttle)
        if security.sso.isEnabled && !security.sso.isEffective {
            // Enabled but unusable — fail closed, but not silently. Name which of `isEffective`'s two
            // preconditions is missing, or an unset `GOEL_PORTAL_PROXY_SECRET` reads as a proxy-list bug.
            let missing = [security.sso.trustedProxies.isEmpty ? "trusted-proxies" : nil,
                           security.sso.sharedSecret.isEmpty ? "shared-secret" : nil]
                .compactMap { $0 }.joined(separator: ",")
            GoelLog.remote.error("Header SSO is enabled but incomplete — the header will be ignored",
                                 .state(missing, label: "missing"))
        }

        // Never expose an unauthenticated portal: without sign-in ``RemoteRouter/authorize`` grants the
        // whole mutating API to the subnet. `requireAuth` alone isn't enough — a real password is required.
        let exposeLAN = allowLAN && config.requireAuth && !passwordHash.isEmpty
        if allowLAN && !exposeLAN {
            let why = config.requireAuth ? "no-portal-password" : "sign-in-disabled"
            GoelLog.remote.notice("LAN access refused; binding 127.0.0.1 only",
                                  .state(why, label: "reason"))
        } else if exposeLAN, !security.tlsEnabled, boundExposeLAN != true {
            // LAN over plain HTTP sends login/cookie/token unencrypted. Warn once per bind so the
            // operator enables portal TLS, trusts the network, or terminates TLS at a reverse proxy.
            GoelLog.remote.notice("Portal exposed on the LAN over plain HTTP — enable portal TLS, use a trusted network, or put it behind a TLS reverse proxy")
        }

        // The socket's protocol stack is part of its identity, so a TLS toggle or a
        // swapped certificate must force a rebind rather than being applied live.
        let tlsKey = security.tlsEnabled ? "tls:\(security.tlsIdentityPath)" : "plain"

        // Already listening on the same endpoint? The live config above is all that
        // needed to change — keep the socket.
        if listener != nil, boundPort == port, boundExposeLAN == exposeLAN, boundTLS == tlsKey {
            return
        }
        // A real bind change: fully release any existing listener first, so the port
        // is free before we re-create it.
        await stop()

        let listenPort = NWEndpoint.Port(rawValue: port) ?? 8899
        // SO_REUSEADDR as belt-and-braces for any lingering TIME_WAIT; the awaited
        // teardown above is what actually guarantees the port is free.
        let parameters: NWParameters
        if security.tlsEnabled {
            guard let tls = Self.tlsParameters(identityPath: security.tlsIdentityPath) else {
                // Fail closed: falling back to cleartext would hand the operator a portal they believe
                // is encrypted while it quietly is not — the worst outcome of a mistyped cert path.
                GoelLog.remote.error("Portal TLS is enabled but the identity could not be loaded — refusing to serve cleartext",
                                     .path(security.tlsIdentityPath))
                startFailure = .tlsIdentityUnavailable(path: security.tlsIdentityPath)
                return
            }
            parameters = tls
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        if !exposeLAN {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: listenPort)
        }
        let newListener: NWListener?
        if exposeLAN {
            newListener = try? NWListener(using: parameters, on: listenPort)
        } else {
            newListener = try? NWListener(using: parameters)
        }
        guard let newListener else {
            GoelLog.remote.error("Remote server failed to bind", .count(Int(port), label: "port"))
            startFailure = .bindFailed(port: port)
            return
        }
        // Advertise over Bonjour only when actually exposed to the network — a
        // loopback-only server has nothing to announce.
        if exposeLAN {
            newListener.service = NWListener.Service(name: "GoelDownloader", type: "_http._tcp")
        }
        // Surface a listener that fails *after* start() — otherwise a bad bind leaves the UI claiming
        // the portal is on with nothing behind it, exactly the state that made this hard to diagnose.
        let portForLog = listenPort.rawValue
        newListener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                GoelLog.remote.error("Remote server listener failed",
                                     .count(Int(portForLog), label: "port"),
                                     .detail(String(describing: error)))
            case .waiting(let error):
                GoelLog.remote.notice("Remote server waiting",
                                      .count(Int(portForLog), label: "port"),
                                      .detail(String(describing: error)))
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            // Bound before the Task — see DownloadManager.updates(). Only moves the check out of the
            // concurrently-executing closure; a dead server drops the connection either way.
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        newListener.start(queue: DispatchQueue(label: "goel.remote-server"))
        self.listener = newListener
        self.boundPort = port
        self.boundExposeLAN = exposeLAN
        self.boundTLS = tlsKey
        // Something is listening again — any earlier refusal is stale.
        self.startFailure = nil
    }

    // MARK: TLS

    /// TLS parameters from a PKCS#12 identity on disk, or `nil` if unloadable. `.p12` is the only form
    /// macOS consumes without a third-party crypto lib; `Deploy/README.md` has the `openssl` commands.
    private static func tlsParameters(identityPath: String) -> NWParameters? {
        guard let identity = loadIdentity(path: identityPath) else { return nil }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        return NWParameters(tls: options)
    }

    private static func loadIdentity(path: String) -> sec_identity_t? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = FileManager.default.contents(atPath: trimmed) else {
            return nil
        }
        // The passphrase comes from the environment, never from settings — see
        // ``RemotePortalSecurity/tlsPassphrase``.
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: RemotePortalSecurity.tlsPassphrase,
        ]
        if #available(macOS 15.0, *) {
            // Keep the imported key in this process only; on earlier systems it lands in the login
            // keychain — hence the deployment guide's dedicated (not shared) certificate advice.
            options[kSecImportToMemoryOnly as String] = kCFBooleanTrue as Any
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let first = entries.first,
              let raw = first[kSecImportItemIdentity as String] else {
            GoelLog.remote.error("PKCS#12 import failed for the portal certificate",
                                 .code(Int(status), label: "osstatus"))
            return nil
        }
        let identity = raw as! SecIdentity
        return sec_identity_create(identity)
    }

    /// Stopping awaits the listener's `.cancelled` state, so a later `start()` rebinds without EADDRINUSE
    /// (cancel is async). Port/LAN exposure of the live listener, or nil — ``RemoteAccess`` uses it for `isRunning`.
    public func boundState() -> (port: UInt16, exposedLAN: Bool)? {
        guard listener != nil, let p = boundPort else { return nil }
        return (p, boundExposeLAN ?? false)
    }

    /// Why nothing is listening after the last `start`, or nil when bound. Companion to ``boundState()``:
    /// that answers *whether* the portal is up, this answers *why not* in words a person can act on.
    public func lastStartFailure() -> StartFailure? { startFailure }

    public func stop() async {
        generation += 1
        // A deliberate stop is not a failure, and the next `start` re-decides.
        startFailure = nil
        boundPort = nil
        boundExposeLAN = nil
        boundTLS = nil
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Resume exactly once, from whichever fires first — listener terminal state or backstop
            // timer. A `@Sendable` one-shot keeps this correct across the two concurrent callbacks.
            let once = OneShotResume(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: once.fire()
                default: break
                }
            }
            // Backstop: if the listener was already terminal, setting the handler above won't re-fire
            // it — don't hang teardown waiting for a state that will never come.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { once.fire() }
            listener.cancel()
        }
    }

    // MARK: Connection handling

    /// Gate new connections behind the concurrency cap, then arm an idle timeout so a client that
    /// connects and sends nothing can't hold a slot (and its Task/queue) open forever.
    private func accept(_ connection: NWConnection) {
        guard openConnections < Self.maxConnections else {
            connection.cancel()
            return
        }
        openConnections += 1
        liveConnections.insert(ObjectIdentifier(connection))
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.receiveTimeout)
            if !Task.isCancelled {
                connection.cancel()
                await self?.connectionClosed(connection)
            }
        }
        connection.start(queue: DispatchQueue(label: "goel.remote-conn"))
        readRequest(connection, buffer: Data(), timeout: timeout,
                    client: Self.clientAddress(connection))
    }

    /// The peer's IP as the socket reports it — the *only* address auth trusts, since unlike
    /// `X-Forwarded-For` a client can't choose it. Keys the login throttle and the trusted-proxy check.
    private static func clientAddress(_ connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default:        return ""
        }
    }

    /// Read until a COMPLETE request arrives (`\r\n\r\n` plus a body ≥ `Content-Length`), then dispatch
    /// once — one `receive` sees a POST body trailing in a later segment as truncated/empty → 400.
    private nonisolated func readRequest(_ connection: NWConnection, buffer: Data,
                                         timeout: Task<Void, Never>, client: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk, !chunk.isEmpty { buffer.append(chunk) }

            func abort() {
                timeout.cancel()
                connection.cancel()
                Task { await self.connectionClosed(connection) }
            }
            // Peer error or an oversized request: give up.
            if error != nil || buffer.count > Self.maxRequestBytes { return abort() }
            guard let bodyStart = RemoteRequest.headerEnd(buffer) else {
                if isComplete { return abort() }          // closed mid-headers
                return self.readRequest(connection, buffer: buffer, timeout: timeout, client: client)
            }
            let needBody = RemoteRequest.contentLength(buffer.prefix(bodyStart))
            if buffer.count - bodyStart < needBody {
                if isComplete { return abort() }          // closed mid-body
                return self.readRequest(connection, buffer: buffer, timeout: timeout, client: client)
            }
            // Whole request in hand — the idle timeout has done its job.
            timeout.cancel()
            let data = buffer
            Task { await self.serve(connection, RemoteRequest(raw: data), client: client) }
        }
    }

    /// Dispatch a fully-read request. Streaming routes hold the connection open and
    /// send incrementally; everything else is one response and done.
    private func serve(_ connection: NWConnection, _ request: RemoteRequest, client: String) async {
        switch (request.method, request.path) {
        case ("GET", "/api/events"):
            await serveEvents(connection, request, client: client)
        case ("GET", "/stream"):
            await serveStream(connection, request, client: client)
        default:
            let response = await respond(to: request, client: client)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        await connectionClosed(connection)
    }

    /// Send one buffer, reporting whether the stack accepted it. A torn-down
    /// connection reports an error here, which ends the streaming loops.
    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    // MARK: Server-sent events (live updates without polling)

    /// `GET /api/events` — an SSE stream pushing the task list every ~1.5 s.
    /// Ends when the client goes away (send fails) or the server restarts.
    private func serveEvents(_ connection: NWConnection, _ request: RemoteRequest,
                             client: String) async {
        let router = self.router
        guard router.authorize(request, sessionAuthed: await portalAuthed(request, client: client)) else {
            _ = await send(connection, RemoteRouter.response(status: "401 Unauthorized",
                                                             type: "text/plain",
                                                             body: Data("Invalid token\n".utf8)))
            connection.cancel()
            return
        }
        guard sseConnections < Self.maxSSEConnections else {
            _ = await send(connection, RemoteRouter.response(status: "503 Service Unavailable",
                                                             type: "text/plain",
                                                             body: Data("Too many live streams\n".utf8)))
            connection.cancel()
            return
        }
        sseConnections += 1
        let myGeneration = generation
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        if await send(connection, Data(head.utf8)) {
            while generation == myGeneration, let manager {
                guard let frame = router.eventFrame(for: await manager.taskSnapshot()) else {
                    // Skip the tick rather than pushing an empty list, which would
                    // blank the client's view of a queue that is still running.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                guard await send(connection, frame) else { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        connection.cancel()
        sseConnections -= 1
    }

    /// Release a connection's slot exactly once, however many teardown paths
    /// (idle timeout, receive failure, response completion) race to do it.
    private func connectionClosed(_ connection: NWConnection) {
        guard liveConnections.remove(ObjectIdentifier(connection)) != nil else { return }
        openConnections = max(0, openConnections - 1)
    }

    // MARK: Auth, sessions & login (stateful — the pure router can't do these)

    /// One non-streaming request: cookie sessions + login/logout here, the rest delegates to the pure
    /// router. Browser page-loads bounce to `/login`; `/api` gets a 401 so script clients see a status.
    private func respond(to request: RemoteRequest, client: String) async -> Data {
        let authed = await portalAuthed(request, client: client)
        let cfg = routerConfig

        // Ahead of every gate: the login page can't style itself or submit without these, and they
        // are the same public bytes for everyone. See `RemoteRouter.staticAsset(path:)`.
        if request.method == "GET", let asset = RemoteRouter.staticAsset(path: request.path) {
            return asset
        }

        switch (request.method, request.path) {
        case ("GET", "/login"):
            if authed || !cfg.requireAuth { return Self.redirect(to: "/") }
            return Self.htmlResponse(RemoteRouter.loginPage(theme: cfg.theme, error: nil))
        case ("POST", "/login"):
            // A foreign page must not be able to force-log-in a victim, so the
            // login route takes the same Origin check as every other POST.
            guard RemoteRouter.crossSiteWriteAllowed(request) else {
                return RemoteRouter.forbidden("Cross-site request refused.")
            }
            return await handleLogin(request, client: client)
        case ("GET", "/logout"), ("POST", "/logout"):
            // Sign-out drops the session AND bumps the generation, winding down every live stream —
            // ungated it let any unauthenticated `curl` do that, so use the same predicate as other routes.
            guard router.authorize(request, sessionAuthed: authed) else {
                return request.method == "GET"
                    ? Self.redirect(to: "/login")
                    : RemoteRouter.response(status: "401 Unauthorized", type: "text/plain",
                                            body: Data("Not signed in\n".utf8))
            }
            return await handleLogout(request)
        default:
            if RemoteAuthService.shouldPromoteTokenToSession(
                request, requireAuth: cfg.requireAuth,
                sessionAuthed: authed, tokenAuthed: tokenAuthed(request)) {
                return RemoteRouter.response(
                    status: "200 OK", type: "text/html; charset=utf-8",
                    body: Data(RemoteRouter.page(config: cfg).utf8),
                    extraHeaders: ["Set-Cookie": await sessionStore.issueSession()])
            }
            if cfg.requireAuth, !authed, !tokenAuthed(request),
               request.method == "GET", !request.path.hasPrefix("/api") {
                return Self.redirect(to: "/login")
            }
            return await router.handle(request, sessionAuthed: authed)
        }
    }

    private func validSession(_ request: RemoteRequest) async -> Bool {
        await sessionStore.validSession(request)
    }

    /// Signed in by session cookie, or by an identity a trusted upstream proxy already verified?
    /// The SSO branch is inert unless enabled *and* the proxy's address is listed — default: cookie only.
    private func portalAuthed(_ request: RemoteRequest, client: String) async -> Bool {
        if await sessionStore.validSession(request) { return true }
        return RemoteAuthService.trustedIdentity(request, client: client,
                                                 policy: security.sso) != nil
    }

    private func tokenAuthed(_ request: RemoteRequest) -> Bool {
        RemoteAuthService.tokenAuthed(request, token: routerConfig.token)
    }

    private func handleLogin(_ request: RemoteRequest, client: String) async -> Data {
        await sessionStore.handleLogin(request, client: client)
    }

    private func handleLogout(_ request: RemoteRequest) async -> Data {
        let result = await sessionStore.handleLogout(request)
        // Only a real sign-out needs the bump (it forces open SSE/byte-range loops to re-auth);
        // bumping for a logout that dropped nothing turned one stray request into dead streams.
        if result.droppedSession { generation += 1 }
        return result.response
    }

    private static func redirect(to location: String) -> Data {
        RemoteAuthService.redirect(to: location)
    }

    private static func htmlResponse(_ html: String) -> Data {
        RemoteAuthService.htmlResponse(html)
    }

    // MARK: File streaming (watch while downloading / play remotely)

    /// `GET /stream?id=<task>` — serve a task's payload with Range support. Finished tasks stream whole;
    /// a sequential in-progress torrent streams its contiguous prefix (behind a safety margin).
    private func serveStream(_ connection: NWConnection, _ request: RemoteRequest,
                             client: String) async {
        func reject(_ status: String, _ message: String) async {
            _ = await send(connection, RemoteRouter.response(status: status, type: "text/plain",
                                                             body: Data("\(message)\n".utf8)))
            connection.cancel()
        }
        guard router.authorize(request, sessionAuthed: await portalAuthed(request, client: client)) else {
            return await reject("401 Unauthorized", "Not signed in")
        }
        guard let manager,
              let id = request.query["id"].flatMap(UUID.init(uuidString:)),
              let task = await manager.task(id) else {
            return await reject("404 Not Found", "No such download")
        }
        guard let plan = Self.streamPlan(for: task) else {
            return await reject("409 Conflict", "Not streamable yet — finish the download or enable sequential mode")
        }
        guard let handle = FileHandle(forReadingAtPath: plan.path) else {
            return await reject("404 Not Found", "File missing on disk")
        }
        defer { try? handle.close() }

        // Clamp the requested range to the bytes that verifiably exist.
        let available = plan.availableBytes
        // A finished but empty (0-byte) payload is valid: reply 200 with an empty
        // body instead of pretending the download hasn't produced anything yet.
        if available == 0 {
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: \(Self.mimeType(forPath: plan.path))\r\n"
            head += "Content-Length: 0\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "X-Content-Type-Options: nosniff\r\n"
            head += "Connection: close\r\n\r\n"
            _ = await send(connection, Data(head.utf8))
            connection.cancel()
            return
        }
        var start: Int64 = 0
        var end: Int64 = available - 1
        var status = "200 OK"
        if let range = request.headers["range"],
           let parsed = Self.parseByteRange(range, available: available) {
            (start, end) = parsed
            status = "206 Partial Content"
        }
        guard start <= end else { return await reject("416 Range Not Satisfiable", "Bad range") }

        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(Self.mimeType(forPath: plan.path))\r\n"
        head += "Content-Length: \(end - start + 1)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if status.hasPrefix("206") {
            head += "Content-Range: bytes \(start)-\(end)/\(plan.totalBytes)\r\n"
        }
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        let myGeneration = generation
        guard await send(connection, Data(head.utf8)) else { connection.cancel(); return }

        // Body in bounded chunks so a multi-gigabyte file never sits in memory.
        var cursor = start
        try? handle.seek(toOffset: UInt64(start))
        while cursor <= end, generation == myGeneration {
            let want = Int(min(Int64(512 * 1024), end - cursor + 1))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            guard await send(connection, chunk) else { break }
            cursor += Int64(chunk.count)
        }
        connection.cancel()
    }

    // MARK: Stream planning — shared with Linux via ``RemoteStreamService``

    public typealias StreamPlan = RemoteStreamService.StreamPlan

    public static func streamPlan(for task: DownloadTask) -> StreamPlan? {
        RemoteStreamService.streamPlan(for: task)
    }

    static func parseByteRange(_ header: String, available: Int64) -> (Int64, Int64)? {
        RemoteStreamService.parseByteRange(header, available: available)
    }

    static func mimeType(forPath path: String) -> String {
        RemoteStreamService.mimeType(forPath: path)
    }

    /// Kept for source/test compatibility; the implementation now lives in
    /// ``RemoteRouter/constantTimeEquals(_:_:)``.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        RemoteRouter.constantTimeEquals(a, b)
    }
}

/// Thread-safe one-shot resume for a `CheckedContinuation` signalled by several concurrent callbacks
/// (listener terminal state, timeout backstop). Resuming twice traps, so first caller wins.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cont: CheckedContinuation<Void, Never>
    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
    func fire() {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { cont.resume() }
    }
}
#endif
