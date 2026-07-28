#if os(Linux)
import Foundation
import NIOCore
import NIOPosix
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor RemoteControlServer {

    private weak var manager: RemoteBackend?

    private var routerConfig = RemoteRouter.Config(token: "")
    private var passwordHash = ""
    private let sessionStore = RemoteSessionStore()
    private var security = RemotePortalSecurity()
    /// Bumping this is what winds down every live SSE / streaming loop.
    private var generation = 0

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var gate: ConnectionGate?
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?

    public typealias StartFailure = RemotePortalStartFailure
    private var startFailure: StartFailure?

    private var sseConnections = 0
    private static let maxConnections = 32
    private static let maxSSEConnections = 4

    private var router: RemoteRouter { RemoteRouter(backend: manager, config: routerConfig) }

    public init(manager: RemoteBackend) {
        self.manager = manager
    }

    public func start(port: UInt16, allowLAN: Bool, config: RemoteRouter.Config,
                      passwordHash: String, sessionMinutes: Int,
                      security: RemotePortalSecurity = RemotePortalSecurity()) async {
        let credentialsChanged = config.username != routerConfig.username
            || config.requireAuth != routerConfig.requireAuth
            || config.token != routerConfig.token
            || passwordHash != self.passwordHash
        if credentialsChanged {
            // Token rotation counts too: a leaked token's open stream must be torn down.
            generation += 1
        }
        self.routerConfig = config
        self.passwordHash = passwordHash
        self.security = security
        // One hop: a separate rotate-then-drop would let a login slip through on stale credentials.
        await sessionStore.configure(username: config.username, passwordHash: passwordHash,
                                     sessionMinutes: sessionMinutes,
                                     invalidatingSessions: credentialsChanged)
        await sessionStore.configure(throttle: security.throttle)
        if security.sso.isEnabled && !security.sso.isEffective {
            let missing = [security.sso.trustedProxies.isEmpty ? "trusted-proxies" : nil,
                           security.sso.sharedSecret.isEmpty ? "shared-secret" : nil]
                .compactMap { $0 }.joined(separator: ",")
            GoelLog.remote.error("Header SSO is enabled but incomplete — the header will be ignored",
                                 .state(missing, label: "missing"))
        }

        // No NIOSSL on Linux: refuse to start rather than silently serve the portal in cleartext.
        if security.tlsEnabled {
            GoelLog.remote.error("Portal TLS is not supported by the Linux daemon — terminate TLS at a reverse proxy; refusing to serve cleartext")
            await stop()
            // Must follow `stop()`, which clears `startFailure`.
            startFailure = .tlsUnsupported
            return
        }

        // Both conditions are load-bearing: `requireAuth` without a password still exposes the write API.
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
        startFailure = nil
        boundPort = nil
        boundExposeLAN = nil
        gate = nil
        let ch = channel; channel = nil
        let g = group; group = nil
        guard ch != nil || g != nil else { return }
        // Raced against a timer: a hung NIO teardown would wedge the actor and deadlock the next start().
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

    public func boundState() -> (port: UInt16, exposedLAN: Bool)? {
        guard channel != nil, let p = boundPort else { return nil }
        return (p, boundExposeLAN ?? false)
    }

    public func lastStartFailure() -> StartFailure? { startFailure }

    func dispatch(requestData: Data, sink: ChannelSink, client: String) async {
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
                    // Skipping the tick, not sending an empty list, which would blank a live queue.
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

    private func respond(to request: RemoteRequest, client: String) async -> Data {
        let authed = await portalAuthed(request, client: client)
        let cfg = routerConfig

        // Deliberately pre-auth: the login page cannot render without them, and they are public bytes.
        if request.method == "GET", let asset = RemoteRouter.staticAsset(path: request.path) {
            return asset
        }

        switch (request.method, request.path) {
        case ("GET", "/login"):
            if authed || !cfg.requireAuth { return Self.redirect(to: "/") }
            return Self.htmlResponse(RemoteRouter.loginPage(theme: cfg.theme, error: nil))
        case ("POST", "/login"):
            // CSRF: without this a foreign page can force-log-in a victim.
            guard RemoteRouter.crossSiteWriteAllowed(request) else {
                return RemoteRouter.forbidden("Cross-site request refused.")
            }
            return await handleLogin(request, client: client)
        case ("GET", "/logout"), ("POST", "/logout"):
            // Gated because logout also kills every live stream — otherwise an anonymous curl could.
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

    /// Must stay identical to the macOS shell — auth may not differ between transports.
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
        // Only bump on a real sign-out: an unconditional bump kills every stream on any stray request.
        if result.droppedSession { generation += 1 }
        return result.response
    }

    private static func redirect(to location: String) -> Data {
        RemoteAuthService.redirect(to: location)
    }

    private static func htmlResponse(_ html: String) -> Data {
        RemoteAuthService.htmlResponse(html)
    }

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
        // A finished 0-byte payload is valid; do not turn this into a "not ready" error.
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

/// `@unchecked Sendable` holds only because every `Channel` method hops to the event loop itself.
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

/// Must stay synchronous and lock-based: NIO handlers call it on the event loop, off the actor.
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

final class RequestAccumulator: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let server: RemoteControlServer
    private let gate: ConnectionGate
    private var acquired = false
    private var buffer = Data()
    private var dispatched = false
    private var idleTask: Scheduled<Void>?
    private static let maxRequestBytes = 2 * 1024 * 1024
    private static let idleTimeout = TimeAmount.seconds(15)

    init(server: RemoteControlServer, gate: ConnectionGate) {
        self.server = server
        self.gate = gate
    }

    func channelActive(context: ChannelHandlerContext) {
        // Capped before a buffer is allocated: a flood of slow clients would otherwise exhaust memory.
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
        // After dispatch the sink owns the socket; without this a duplex client grows `buffer` unbounded.
        if dispatched { return }
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        if buffer.count > Self.maxRequestBytes { context.close(promise: nil); return }
        guard let bodyStart = Self.headerEnd(buffer) else { return }
        let needBody = Self.contentLength(buffer.prefix(bodyStart))
        if buffer.count - bodyStart < needBody { return }

        dispatched = true
        idleTask?.cancel()
        let requestData = buffer
        buffer = Data()
        let sink = ChannelSink(context.channel)
        let server = self.server
        // Kernel peer address, never a header: the throttle and trusted-proxy check key off this.
        let client = context.channel.remoteAddress?.ipAddress ?? ""
        Task { await server.dispatch(requestData: requestData, sink: sink, client: client) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

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
