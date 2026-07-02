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

    private weak var manager: DownloadManager?

    // Routing config + login state (identical semantics to the macOS shell).
    private var routerConfig = RemoteRouter.Config(token: "")
    private var passwordHash = ""
    private var sessionSeconds = 120 * 60
    private var sessions: [String: Date] = [:]
    private var loginFailCount = 0
    private var loginLockUntil: Date?
    /// Bumped on every start/stop so long-lived SSE / streaming loops wind down.
    private var generation = 0

    // NIO transport handles.
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?

    // Concurrency caps (mirror the macOS shell).
    private var openConnections = 0
    private var sseConnections = 0
    private static let maxConnections = 32
    private static let maxSSEConnections = 4

    private var router: RemoteRouter { RemoteRouter(backend: manager, config: routerConfig) }

    public init(manager: DownloadManager) {
        self.manager = manager
    }

    // MARK: Lifecycle

    public func start(port: UInt16, allowLAN: Bool, config: RemoteRouter.Config,
                      passwordHash: String, sessionMinutes: Int) async {
        let credentialsChanged = config.username != routerConfig.username
            || config.requireAuth != routerConfig.requireAuth
            || passwordHash != self.passwordHash
        if credentialsChanged {
            sessions.removeAll()
            generation += 1
        }
        self.routerConfig = config
        self.passwordHash = passwordHash
        self.sessionSeconds = max(5, sessionMinutes) * 60

        // Never expose an unauthenticated portal to the network.
        let exposeLAN = allowLAN && config.requireAuth
        if allowLAN && !exposeLAN {
            FileHandle.standardError.write(Data("[GoelDownloader] LAN access ignored — sign-in is disabled, binding 127.0.0.1 only\n".utf8))
        }

        if channel != nil, boundPort == port, boundExposeLAN == exposeLAN { return }
        await stop()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let host = exposeLAN ? "0.0.0.0" : "127.0.0.1"
        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.addHandler(RequestAccumulator(server: server))
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
        if let ch = channel {
            channel = nil
            try? await ch.close()
        }
        if let g = group {
            group = nil
            try? await g.shutdownGracefully()
        }
    }

    // MARK: Dispatch (called by the per-connection handler once a request is whole)

    func dispatch(requestData: Data, sink: ChannelSink) async {
        guard openConnections < Self.maxConnections else { sink.close(); return }
        openConnections += 1
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
        openConnections = max(0, openConnections - 1)
    }

    // MARK: Server-sent events

    private func serveEvents(_ sink: ChannelSink, _ request: RemoteRequest) async {
        let router = self.router
        guard router.authorize(request, sessionAuthed: validSession(request)) else {
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
                let frame = router.eventFrame(for: await manager.snapshot)
                guard await sink.send(frame) else { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        sink.close()
        sseConnections = max(0, sseConnections - 1)
    }

    // MARK: Auth, sessions & login

    private func respond(to request: RemoteRequest) async -> Data {
        let authed = validSession(request)
        let cfg = routerConfig
        switch (request.method, request.path) {
        case ("GET", "/login"):
            if authed || !cfg.requireAuth { return Self.redirect(to: "/") }
            return Self.htmlResponse(RemoteRouter.loginPage(theme: cfg.theme, error: nil))
        case ("POST", "/login"):
            return await handleLogin(request)
        case ("GET", "/logout"), ("POST", "/logout"):
            return handleLogout(request)
        default:
            if cfg.requireAuth, !authed, !tokenAuthed(request),
               request.method == "GET", !request.path.hasPrefix("/api") {
                return Self.redirect(to: "/login")
            }
            return await router.handle(request, sessionAuthed: authed)
        }
    }

    private func validSession(_ request: RemoteRequest) -> Bool {
        guard let sid = request.cookie("goel_session"), let expiry = sessions[sid] else { return false }
        guard expiry > Date() else { sessions[sid] = nil; return false }
        return true
    }

    private func tokenAuthed(_ request: RemoteRequest) -> Bool {
        let token = routerConfig.token
        guard !token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           RemoteRouter.constantTimeEquals(header, "Bearer \(token)") { return true }
        if let query = request.query["token"] { return RemoteRouter.constantTimeEquals(query, token) }
        return false
    }

    private func handleLogin(_ request: RemoteRequest) async -> Data {
        let creds = Self.parseCredentials(request)
        let userOK = RemoteRouter.constantTimeEquals(creds.username, routerConfig.username)
        let hash = passwordHash
        let password = creds.password
        let passOK: Bool = hash.isEmpty
            ? false
            : await Task.detached { RemotePassword.verify(password, against: hash) }.value

        if userOK && passOK {
            loginFailCount = 0
            loginLockUntil = nil
            pruneSessions()
            let sid = RemotePassword.randomHex(bytes: 32)
            sessions[sid] = Date().addingTimeInterval(TimeInterval(sessionSeconds))
            let cookie = "goel_session=\(sid); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(sessionSeconds)"
            return RemoteRouter.response(status: "200 OK", type: "application/json",
                                         body: Data("{\"ok\":true}".utf8),
                                         extraHeaders: ["Set-Cookie": cookie])
        }

        if let until = loginLockUntil, until > Date() {
            return Self.jsonError(status: "429 Too Many Requests",
                                  message: "Too many attempts — wait a moment and try again.")
        }
        loginFailCount += 1
        if loginFailCount >= 5 {
            loginLockUntil = Date().addingTimeInterval(30)
            loginFailCount = 0
        }
        let message = hash.isEmpty
            ? "No portal password is set yet — set one in the app under Settings → Web Access."
            : "Wrong username or password."
        return Self.jsonError(status: "401 Unauthorized", message: message)
    }

    private func handleLogout(_ request: RemoteRequest) -> Data {
        if let sid = request.cookie("goel_session") { sessions[sid] = nil }
        let cookie = "goel_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        return RemoteRouter.response(status: "200 OK", type: "application/json",
                                     body: Data("{\"ok\":true}".utf8),
                                     extraHeaders: ["Set-Cookie": cookie])
    }

    private func pruneSessions() {
        let now = Date()
        sessions = sessions.filter { $0.value > now }
    }

    private static func parseCredentials(_ request: RemoteRequest) -> (username: String, password: String) {
        struct Creds: Decodable { var username: String?; var password: String? }
        if let obj = try? JSONDecoder().decode(Creds.self, from: request.body) {
            return (obj.username ?? "", obj.password ?? "")
        }
        var username = "", password = ""
        for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            if kv[0] == "username" { username = value } else if kv[0] == "password" { password = value }
        }
        return (username, password)
    }

    private static func redirect(to location: String) -> Data {
        RemoteRouter.response(status: "303 See Other", type: "text/plain",
                              body: Data(), extraHeaders: ["Location": location])
    }

    private static func htmlResponse(_ html: String) -> Data {
        RemoteRouter.response(status: "200 OK", type: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private static func jsonError(status: String, message: String) -> Data {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        return RemoteRouter.response(status: status, type: "application/json",
                                     body: Data("{\"ok\":false,\"error\":\"\(safe)\"}".utf8))
    }

    // MARK: File streaming (Range support)

    private func serveStream(_ sink: ChannelSink, _ request: RemoteRequest) async {
        func reject(_ status: String, _ message: String) async {
            _ = await sink.send(RemoteRouter.response(status: status, type: "text/plain",
                                                      body: Data("\(message)\n".utf8)))
            sink.close()
        }
        guard router.authorize(request, sessionAuthed: validSession(request)) else {
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
        guard available > 0 else { return await reject("409 Conflict", "Nothing downloaded yet") }
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

    // MARK: Stream planning (pure — mirrors the macOS shell)

    public struct StreamPlan {
        var path: String
        var totalBytes: Int64
        var availableBytes: Int64
    }

    public static func streamPlan(for task: DownloadTask) -> StreamPlan? {
        if task.status.hasData {
            var path = task.savePath
            if task.isMultiFile,
               let largest = task.files.filter(\.isWanted).max(by: { $0.length < $1.length }) {
                path = (task.saveDirectory as NSString).appendingPathComponent(largest.path)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return nil }
            return StreamPlan(path: path, totalBytes: size, availableBytes: size)
        }
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return nil }
        let margin: Int64 = 8 * 1024 * 1024
        let available = max(0, task.bytesDownloaded - margin)
        guard available > 0 else { return nil }
        return StreamPlan(path: task.savePath, totalBytes: total, availableBytes: available)
    }

    static func parseByteRange(_ header: String, available: Int64) -> (Int64, Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst("bytes=".count).split(separator: ",")[0]
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, available - n), available - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < available else { return nil }
        let end = Int64(parts[1]).map { min($0, available - 1) } ?? (available - 1)
        return (start, end)
    }

    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
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

/// Per-connection inbound handler: accumulates the raw HTTP request (headers, plus
/// any `Content-Length` body), then hands the whole thing to the actor exactly
/// once. An idle timeout closes a client that connects and sends nothing.
final class RequestAccumulator: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let server: RemoteControlServer
    private var buffer = Data()
    private var dispatched = false
    private var idleTask: Scheduled<Void>?
    private static let maxRequestBytes = 2 * 1024 * 1024   // headers + body ceiling
    private static let idleTimeout = TimeAmount.seconds(15)

    init(server: RemoteControlServer) { self.server = server }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        idleTask = context.eventLoop.scheduleTask(in: Self.idleTimeout) { [weak self] in
            if self?.dispatched != true { channel.close(promise: nil) }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let bytes = incoming.readBytes(length: incoming.readableBytes) {
            buffer.append(contentsOf: bytes)
        }
        guard !dispatched else { return }
        if buffer.count > Self.maxRequestBytes { context.close(promise: nil); return }
        guard let bodyStart = Self.headerEnd(buffer) else { return }   // headers incomplete
        let needBody = Self.contentLength(buffer.prefix(bodyStart))
        if buffer.count - bodyStart < needBody { return }              // body incomplete

        dispatched = true
        idleTask?.cancel()
        let requestData = buffer
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
