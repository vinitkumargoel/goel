#if os(Linux)
import Foundation
import GoelContracts
import GoelCore
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
    /// Bumped on every start/stop so long-lived SSE / streaming loops wind down.
    private var generation = 0

    // NIO transport handles.
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var gate: ConnectionGate?
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?

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
                      passwordHash: String, sessionMinutes: Int) async {
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
        // Single hop: rotate credentials and drop sessions together, so no login
        // can slip through this actor's suspension holding stale credentials.
        await sessionStore.configure(username: config.username, passwordHash: passwordHash,
                                     sessionMinutes: sessionMinutes,
                                     invalidatingSessions: credentialsChanged)

        // Never expose the portal to the network unless sign-in is required AND a
        // password actually exists. `requireAuth` alone is just the policy toggle;
        // with no password the mutating API is still reachable on the LAN via the
        // bearer token, so a passwordless config must stay loopback-only.
        let exposeLAN = allowLAN && config.requireAuth && !passwordHash.isEmpty
        if allowLAN && !exposeLAN {
            let why = config.requireAuth ? "no portal password is set" : "sign-in is disabled"
            FileHandle.standardError.write(Data("[GoelDownloader] LAN access refused — \(why); binding 127.0.0.1 only\n".utf8))
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
        } catch {
            FileHandle.standardError.write(Data("[GoelDownloader] remote server failed to bind port \(port): \(error)\n".utf8))
            try? await group.shutdownGracefully()
        }
    }

    public func stop() async {
        generation += 1
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

    // MARK: Dispatch (called by the per-connection handler once a request is whole)

    func dispatch(requestData: Data, sink: ChannelSink) async {
        // Admission is capped at accept time by `ConnectionGate`; here we just route.
        let request = RemoteRequest(raw: requestData)
        switch (request.method, request.path) {
        case ("GET", "/api/events"):
            await serveEvents(sink, request)
        case ("GET", "/stream"):
            await serveStream(sink, request)
        default:
            let response = await respond(to: request)
            _ = await sink.send(response)
            sink.close()
        }
    }

    // MARK: Server-sent events

    private func serveEvents(_ sink: ChannelSink, _ request: RemoteRequest) async {
        let router = self.router
        guard router.authorize(request, sessionAuthed: await validSession(request)) else {
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
                let frame = router.eventFrame(for: await manager.taskSnapshot())
                guard await sink.send(frame) else { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        sink.close()
        sseConnections = max(0, sseConnections - 1)
    }

    // MARK: Auth, sessions & login

    private func respond(to request: RemoteRequest) async -> Data {
        let authed = await validSession(request)
        let cfg = routerConfig
        switch (request.method, request.path) {
        case ("GET", "/login"):
            if authed || !cfg.requireAuth { return Self.redirect(to: "/") }
            return Self.htmlResponse(RemoteRouter.loginPage(theme: cfg.theme, error: nil))
        case ("POST", "/login"):
            return await handleLogin(request)
        case ("GET", "/logout"), ("POST", "/logout"):
            return await handleLogout(request)
        default:
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

    private func tokenAuthed(_ request: RemoteRequest) -> Bool {
        RemoteAuthService.tokenAuthed(request, token: routerConfig.token)
    }

    private func handleLogin(_ request: RemoteRequest) async -> Data {
        await sessionStore.handleLogin(request)
    }

    private func handleLogout(_ request: RemoteRequest) async -> Data {
        generation += 1
        return await sessionStore.handleLogout(request)
    }

    private static func redirect(to location: String) -> Data {
        RemoteAuthService.redirect(to: location)
    }

    private static func htmlResponse(_ html: String) -> Data {
        RemoteAuthService.htmlResponse(html)
    }

    // MARK: File streaming (Range support)

    private func serveStream(_ sink: ChannelSink, _ request: RemoteRequest) async {
        func reject(_ status: String, _ message: String) async {
            _ = await sink.send(RemoteRouter.response(status: status, type: "text/plain",
                                                      body: Data("\(message)\n".utf8)))
            sink.close()
        }
        guard router.authorize(request, sessionAuthed: await validSession(request)) else {
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
        Task { await server.dispatch(requestData: requestData, sink: sink) }
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
