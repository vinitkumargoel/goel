#if os(Linux)
import Foundation
import NIOCore
import NIOPosix
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ============================================================================
// Linux transport for the remote-access server.
//
// Same public API and behaviour as the macOS `RemoteControlServer` (init / start /
// stop), but the I/O shell is SwiftNIO instead of Network.framework: a
// `ServerBootstrap` binds loopback (or 0.0.0.0 when LAN + sign-in are on), a
// per-connection handler accumulates the raw HTTP request and hands it to the
// actor, and a `ChannelSink` writes responses / SSE frames / byte-range chunks
// back. All routing, auth, the JSON API and the portal page still come from the
// pure `RemoteRouter`; the stateful session/login logic mirrors the macOS shell.
// ============================================================================

public actor RemoteControlServer {

    private weak var manager: RemoteBackend?

    // Routing config + shared session store (identical semantics to the macOS shell).
    private var routerConfig = RemoteRouter.Config(token: "")
    private var passwordHash = ""
    private let sessionStore = RemoteSessionStore()
    /// Login throttling and header SSO. TLS is declined here — see `start`.
    private var security = RemotePortalSecurity()
    /// Bumped on every start/stop so long-lived SSE / streaming loops wind down.
    private var generation = 0

    // NIO transport handles.
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var gate: ConnectionGate?
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?

    /// Why the last `start` left nothing listening. Shared with the macOS shell so
    /// ``RemoteAccess`` reports the same reasons on both transports.
    public typealias StartFailure = RemotePortalStartFailure
    /// Set on each refusal in `start`, cleared the moment a channel is bound or the
    /// server is stopped. Read through ``lastStartFailure()``.
    private var startFailure: StartFailure?

    // Concurrency caps (mirror the macOS shell). The connection cap is enforced at
    // accept time by `gate` (see RequestAccumulator), not after buffering a request.
    private var sseConnections = 0
    private static let maxConnections = 32
    private static let maxSSEConnections = 4

    private var router: RemoteRouter { RemoteRouter(backend: manager, config: routerConfig) }

    public init(manager: RemoteBackend) {
        self.manager = manager
    }

    // MARK: Lifecycle

    public func start(port: UInt16, allowLAN: Bool, config: RemoteRouter.Config,
                      passwordHash: String, sessionMinutes: Int,
                      security: RemotePortalSecurity = RemotePortalSecurity()) async {
        let credentialsChanged = config.username != routerConfig.username
            || config.requireAuth != routerConfig.requireAuth
            || config.token != routerConfig.token
            || passwordHash != self.passwordHash
        if credentialsChanged {
            // Rotating the bearer token counts as a credential change too, so a
            // leaked token's already-open stream is wound down when it's rotated.
            generation += 1
        }
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
            // Name whichever precondition is missing — the proxy list, the shared
            // secret (`GOEL_PORTAL_PROXY_SECRET`), or both — rather than always
            // blaming the proxy list. Matches the macOS shell. `isEnabled` is true
            // here, so at least one is empty and `missing` is never blank.
            let missing = [security.sso.trustedProxies.isEmpty ? "trusted-proxies" : nil,
                           security.sso.sharedSecret.isEmpty ? "shared-secret" : nil]
                .compactMap { $0 }.joined(separator: ",")
            GoelLog.remote.error("Header SSO is enabled but incomplete — the header will be ignored",
                                 .state(missing, label: "missing"))
        }

        // The daemon links SwiftNIO but not NIOSSL, so it cannot terminate TLS
        // itself. Refuse to start rather than serve cleartext on a portal the
        // operator asked to encrypt — on Linux the answer is a TLS-terminating
        // reverse proxy (nginx / Caddy / Traefik) in front of the loopback bind,
        // which is how these boxes are deployed anyway.
        if security.tlsEnabled {
            GoelLog.remote.error("Portal TLS is not supported by the Linux daemon — terminate TLS at a reverse proxy; refusing to serve cleartext")
            await stop()
            // After `stop()`, which clears it — a deliberate stop is not a failure,
            // but this one is, and the operator has to be told why.
            startFailure = .tlsUnsupported
            return
        }

        // Never expose the portal to the network unless sign-in is required AND a
        // password actually exists. `requireAuth` alone is just the policy toggle;
        // with no password the mutating API is still reachable on the LAN via the
        // bearer token, so a passwordless config must stay loopback-only.
        let exposeLAN = allowLAN && config.requireAuth && !passwordHash.isEmpty
        if allowLAN && !exposeLAN {
            let why = config.requireAuth ? "no-portal-password" : "sign-in-disabled"
            GoelLog.remote.notice("LAN access refused; binding 127.0.0.1 only",
                                  .state(why, label: "reason"))
        }

        if channel != nil, boundPort == port, boundExposeLAN == exposeLAN { return }
        await stop()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let host = exposeLAN ? "0.0.0.0" : "127.0.0.1"
        let server = self
        let gate = ConnectionGate(limit: Self.maxConnections)
        self.gate = gate
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.addHandler(RequestAccumulator(server: server, gate: gate))
            }
        do {
            let ch = try await bootstrap.bind(host: host, port: Int(port)).get()
            self.group = group
            self.channel = ch
            self.boundPort = port
            self.boundExposeLAN = exposeLAN
            // Something is listening again — any earlier refusal is stale.
            self.startFailure = nil
        } catch {
            GoelLog.remote.error("Remote server failed to bind",
                                 .count(Int(port), label: "port"),
                                 .detail(String(describing: error)))
            startFailure = .bindFailed(port: port)
            try? await group.shutdownGracefully()
        }
    }

    public func stop() async {
        generation += 1
        // A deliberate stop is not a failure, and the next `start` re-decides.
        startFailure = nil
        boundPort = nil
        boundExposeLAN = nil
        gate = nil
        let ch = channel; channel = nil
        let g = group; group = nil
        guard ch != nil || g != nil else { return }
        // Backstop: a hung NIO teardown must not wedge the actor forever (a
        // subsequent start()/dispatch would deadlock behind it). Race the teardown
        // against a timer and move on after 3s. Mirrors the macOS shell's backstop.
        await withTaskGroup(of: Void.self) { tg in
            tg.addTask {
                try? await ch?.close()
                try? await g?.shutdownGracefully()
            }
            tg.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            _ = await tg.next()
            tg.cancelAll()
        }
    }

    /// Live bind state so the daemon can report — and act on — what actually
    /// happened, instead of re-deriving it. `nil` when not listening.
    public func boundState() -> (port: UInt16, exposedLAN: Bool)? {
        guard channel != nil, let p = boundPort else { return nil }
        return (p, boundExposeLAN ?? false)
    }

    /// Why nothing is listening after the last `start`, or nil when the portal is
    /// bound. The companion to ``boundState()``: that answers *whether* the portal
    /// is up, this answers *why not* in words a person can act on.
    public func lastStartFailure() -> StartFailure? { startFailure }

    // MARK: Dispatch (called by the per-connection handler once a request is whole)

    func dispatch(requestData: Data, sink: ChannelSink, client: String) async {
        // Admission is capped at accept time by `ConnectionGate`; here we just route.
        let request = RemoteRequest(raw: requestData)
        switch (request.method, request.path) {
        case ("GET", "/api/events"):
            await serveEvents(sink, request, client: client)
        case ("GET", "/stream"):
            await serveStream(sink, request, client: client)
        default:
            let response = await respond(to: request, client: client)
            _ = await sink.send(response)
            sink.close()
        }
    }

    // MARK: Server-sent events

    private func serveEvents(_ sink: ChannelSink, _ request: RemoteRequest, client: String) async {
        let router = self.router
        guard router.authorize(request, sessionAuthed: await portalAuthed(request, client: client)) else {
            _ = await sink.send(RemoteRouter.response(status: "401 Unauthorized", type: "text/plain",
                                                      body: Data("Invalid token\n".utf8)))
            sink.close(); return
        }
        guard sseConnections < Self.maxSSEConnections else {
            _ = await sink.send(RemoteRouter.response(status: "503 Service Unavailable", type: "text/plain",
                                                      body: Data("Too many live streams\n".utf8)))
            sink.close(); return
        }
        sseConnections += 1
        let myGeneration = generation
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        if await sink.send(Data(head.utf8)) {
            while generation == myGeneration, let manager {
                guard let frame = router.eventFrame(for: await manager.taskSnapshot()) else {
                    // Skip the tick rather than pushing an empty list, which would
                    // blank the client's view of a queue that is still running.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                guard await sink.send(frame) else { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        sink.close()
        sseConnections = max(0, sseConnections - 1)
    }

    // MARK: Auth, sessions & login

    private func respond(to request: RemoteRequest, client: String) async -> Data {
        let authed = await portalAuthed(request, client: client)
        let cfg = routerConfig

        // Ahead of every gate: the login page cannot style itself or run its
        // submit handler without these, and they are the same public bytes for
        // everyone. See `RemoteRouter.staticAsset(path:)`.
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
            // Signing out drops the session AND bumps the generation, winding down
            // every live event stream and byte-range download on the server. Ahead
            // of the auth gate it let any unauthenticated caller do that from a bare
            // `curl`; gate it with the same predicate every other route uses.
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

    /// Session cookie, or an identity vouched for by a trusted upstream proxy.
    /// Mirrors the macOS shell exactly so auth cannot drift between transports.
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
        // Only a real sign-out needs the bump: it is what forces open SSE and
        // byte-range loops to re-authenticate. Bumping it for a logout that dropped
        // nothing turned one stray request into every client's dead stream.
        if result.droppedSession { generation += 1 }
        return result.response
    }

    private static func redirect(to location: String) -> Data {
        RemoteAuthService.redirect(to: location)
    }

    private static func htmlResponse(_ html: String) -> Data {
        RemoteAuthService.htmlResponse(html)
    }

    // MARK: File streaming (Range support)

    private func serveStream(_ sink: ChannelSink, _ request: RemoteRequest, client: String) async {
        func reject(_ status: String, _ message: String) async {
            _ = await sink.send(RemoteRouter.response(status: status, type: "text/plain",
                                                      body: Data("\(message)\n".utf8)))
            sink.close()
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

        let available = plan.availableBytes
        // Finished empty (0-byte) payload is valid — serve 200 with empty body
        // (matches macOS RemoteControlServer; don't pretend the download isn't ready).
        if available == 0 {
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: \(Self.mimeType(forPath: plan.path))\r\n"
            head += "Content-Length: 0\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "X-Content-Type-Options: nosniff\r\n"
            head += "Connection: close\r\n\r\n"
            _ = await sink.send(Data(head.utf8))
            sink.close()
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
        guard await sink.send(Data(head.utf8)) else { sink.close(); return }

        var cursor = start
        try? handle.seek(toOffset: UInt64(start))
        while cursor <= end, generation == myGeneration {
            let want = Int(min(Int64(512 * 1024), end - cursor + 1))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            guard await sink.send(chunk) else { break }
            cursor += Int64(chunk.count)
        }
        sink.close()
    }

    // MARK: Stream planning — shared with macOS via ``RemoteStreamService``

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

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        RemoteRouter.constantTimeEquals(a, b)
    }
}

// MARK: - NIO plumbing

/// Writes response bytes / SSE frames / stream chunks back to a NIO channel. NIO
/// `Channel` methods are thread-safe (they hop to the event loop), so the actor
/// can drive this directly. `send` resolves once the write is flushed.
final class ChannelSink: @unchecked Sendable {
    private let channel: Channel
    init(_ channel: Channel) { self.channel = channel }

    func send(_ data: Data) async -> Bool {
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        do { try await channel.writeAndFlush(buf).get(); return true }
        catch { return false }
    }

    func close() { channel.close(promise: nil) }
}

/// A tiny thread-safe counting semaphore used to cap concurrent connections at
/// accept time (the NIO handlers run on the event loop, so this must be usable
/// synchronously off the actor).
final class ConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock(); count = max(0, count - 1); lock.unlock()
    }
}

/// Per-connection inbound handler: accumulates the raw HTTP request (headers, plus
/// any `Content-Length` body), then hands the whole thing to the actor exactly
/// once. An idle timeout closes a client that connects and sends nothing.
final class RequestAccumulator: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let server: RemoteControlServer
    private let gate: ConnectionGate
    private var acquired = false
    private var buffer = Data()
    private var dispatched = false
    private var idleTask: Scheduled<Void>?
    private static let maxRequestBytes = 2 * 1024 * 1024   // headers + body ceiling
    private static let idleTimeout = TimeAmount.seconds(15)

    init(server: RemoteControlServer, gate: ConnectionGate) {
        self.server = server
        self.gate = gate
    }

    func channelActive(context: ChannelHandlerContext) {
        // Cap concurrent connections at accept time — before allocating a buffer or
        // reading a byte — so a flood of idle/slow clients can't exhaust memory.
        guard gate.tryAcquire() else { context.close(promise: nil); return }
        acquired = true
        let channel = context.channel
        idleTask = context.eventLoop.scheduleTask(in: Self.idleTimeout) { [weak self] in
            if self?.dispatched != true { channel.close(promise: nil) }
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        idleTask?.cancel()
        if acquired { gate.release(); acquired = false }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Once dispatched, the response is owned by the actor/sink (which may hold
        // the socket open for SSE/streaming). Ignore any further inbound bytes so a
        // client can't grow this handler's buffer without bound on a duplex socket.
        if dispatched { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        if buffer.count > Self.maxRequestBytes { context.close(promise: nil); return }
        guard let bodyStart = Self.headerEnd(buffer) else { return }   // headers incomplete
        let needBody = Self.contentLength(buffer.prefix(bodyStart))
        if buffer.count - bodyStart < needBody { return }              // body incomplete

        dispatched = true
        idleTask?.cancel()
        let requestData = buffer
        buffer = Data()   // free the accumulated request; the Task holds its own copy
        let sink = ChannelSink(context.channel)
        let server = self.server
        // The peer address from the kernel, not from a header: this is what the
        // login throttle and the trusted-proxy check key off.
        let client = context.channel.remoteAddress?.ipAddress ?? ""
        Task { await server.dispatch(requestData: requestData, sink: sink, client: client) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// Index just past the `\r\n\r\n` that ends the headers, or nil.
    private static func headerEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data)
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i + 4 }
            i += 1
        }
        return nil
    }

    private static func contentLength(_ header: Data) -> Int {
        for line in String(decoding: header, as: UTF8.self).split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }
}
#endif
