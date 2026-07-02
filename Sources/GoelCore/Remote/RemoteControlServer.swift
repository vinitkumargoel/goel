#if !os(Linux)
import Foundation
import Network

/// The remote-access server: a minimal embedded HTTP endpoint exposing the queue
/// to a phone/other machine — a live web page plus a JSON API (list, pause/resume,
/// add). Token-authenticated; binds loopback-only unless the user explicitly
/// allows LAN access.
///
/// This type is now **just the I/O shell**: the `NWListener`, the connection caps,
/// the SSE loop, and the byte-range file streaming. Every decision — request
/// parsing, routing, auth, the JSON API, the control page — lives in the pure
/// ``RemoteRouter``, which it constructs per request. That split lets ~all of the
/// server's logic be unit-tested through the router with an in-memory backend,
/// while this file keeps only the parts that genuinely need a socket or a file.
public actor RemoteControlServer {

    private weak var manager: DownloadManager?
    private var listener: NWListener?

    /// The bind parameters the live `listener` was created with. Only these two
    /// actually affect the socket, so any *other* settings change updates config in
    /// place instead of tearing the listener down and rebinding — a rebind can't
    /// reclaim the port instantly and used to fail (silently) with EADDRINUSE.
    private var boundPort: UInt16?
    private var boundExposeLAN: Bool?

    /// The current routing config (token, requireAuth, readOnly, theme, username),
    /// snapshotted from settings on each (re)start.
    private var routerConfig = RemoteRouter.Config(token: "")
    /// The stored password hash used to verify logins (never leaves the server).
    private var passwordHash = ""
    /// Session lifetime in seconds.
    private var sessionSeconds = 120 * 60

    /// Live login sessions: opaque cookie id → expiry. Kept here (not in the pure
    /// router) because sessions are inherently stateful and span requests.
    private var sessions: [String: Date] = [:]
    /// Crude brute-force brake: after several failures, logins lock briefly.
    private var loginFailCount = 0
    private var loginLockUntil: Date?

    public init(manager: DownloadManager) {
        self.manager = manager
    }

    /// Live connections, capped so idle clients can't exhaust descriptors.
    /// The identifier set makes teardown exactly-once: the idle timeout and
    /// the receive completion can both race to close the same connection, and
    /// a double decrement would quietly erode the cap.
    private var openConnections = 0
    private var liveConnections = Set<ObjectIdentifier>()
    private static let maxConnections = 32
    private static let receiveTimeout: UInt64 = 10 * 1_000_000_000

    /// Live server-sent-event streams, capped separately (each holds a slot for
    /// its whole lifetime, unlike one-shot requests).
    private var sseConnections = 0
    private static let maxSSEConnections = 4

    /// Bumped on every start/stop so long-lived response loops (SSE, file
    /// streaming) notice a restart and wind down.
    private var generation = 0

    /// A router bound to the current backend + config, rebuilt per use (cheap).
    private var router: RemoteRouter { RemoteRouter(backend: manager, config: routerConfig) }

    /// Start (or reconfigure) listening. `allowLAN: false` binds 127.0.0.1 only.
    ///
    /// `config` carries the token, requireAuth/readOnly flags, portal theme, and
    /// username; `passwordHash` and `sessionMinutes` drive the login flow. Any
    /// change to the credentials (username/password/requireAuth) invalidates
    /// existing sessions, so a password change actually logs everyone out.
    ///
    /// Called on *every* settings change. Only the port and the loopback/LAN choice
    /// affect the socket, so when those are unchanged this just swaps the live config
    /// on the running listener — it does **not** rebind. Rebinding on every change
    /// used to tear the socket down and immediately re-create it, which failed with
    /// EADDRINUSE (the port isn't reclaimable that fast) and, with no state handler,
    /// failed silently: the UI still showed the portal "enabled" with nothing behind
    /// it. A rebind now happens only when the port or LAN exposure actually changes,
    /// and it first `await`s the old listener's full teardown.
    public func start(port: UInt16, allowLAN: Bool, config: RemoteRouter.Config,
                      passwordHash: String, sessionMinutes: Int) async {
        let credentialsChanged = config.username != routerConfig.username
            || config.requireAuth != routerConfig.requireAuth
            || passwordHash != self.passwordHash
        if credentialsChanged {
            // A password/username/sign-in change logs everyone out: drop sessions,
            // and bump the generation so any *already-open* SSE or file-stream loop
            // winds down and has to reconnect (and re-authenticate). Without this,
            // the same-port live-config path below would leave live streams running
            // under the old credentials.
            sessions.removeAll()
            generation += 1
        }
        // Live config — applied whether or not we rebind, so a password / theme /
        // read-only / token change takes effect on the existing socket immediately.
        self.routerConfig = config
        self.passwordHash = passwordHash
        self.sessionSeconds = max(5, sessionMinutes) * 60

        // Refuse to expose an unauthenticated portal to the network. When sign-in
        // is off, ``RemoteRouter/authorize`` grants everyone full control, so a LAN
        // bind would hand the mutating API (add with an arbitrary save folder,
        // remove-with-data, stream) to anyone on the subnet. In that state we force
        // a loopback-only bind regardless of the LAN toggle — the UI warning is
        // then backed by the actual bind, not just advice.
        //
        // `requireAuth` alone is only the *policy* toggle: with it on but no password
        // set, the password login can never succeed, yet ``RemoteRouter/authorize``
        // still accepts the bearer token — so a LAN bind would expose the full
        // mutating API to anyone holding (or sniffing) that token. Require a real
        // password before ever binding to the network.
        let exposeLAN = allowLAN && config.requireAuth && !passwordHash.isEmpty
        if allowLAN && !exposeLAN {
            let why = config.requireAuth ? "no portal password is set" : "sign-in is disabled"
            FileHandle.standardError.write(Data("[GoelDownloader] LAN access refused — \(why); binding 127.0.0.1 only\n".utf8))
        }

        // Already listening on the same endpoint? The live config above is all that
        // needed to change — keep the socket.
        if listener != nil, boundPort == port, boundExposeLAN == exposeLAN {
            return
        }
        // A real bind change: fully release any existing listener first, so the port
        // is free before we re-create it.
        await stop()

        let listenPort = NWEndpoint.Port(rawValue: port) ?? 8899
        // SO_REUSEADDR as belt-and-braces for any lingering TIME_WAIT; the awaited
        // teardown above is what actually guarantees the port is free.
        let parameters = NWParameters.tcp
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
            FileHandle.standardError.write(Data("[GoelDownloader] remote server failed to bind port \(port)\n".utf8))
            return
        }
        // Advertise over Bonjour only when actually exposed to the network — a
        // loopback-only server has nothing to announce.
        if exposeLAN {
            newListener.service = NWListener.Service(name: "GoelDownloader", type: "_http._tcp")
        }
        // Surface a listener that fails *after* start() — otherwise a bad bind
        // leaves the UI claiming the portal is on with nothing behind it, exactly
        // the state that made this hard to diagnose.
        let portForLog = listenPort.rawValue
        newListener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                FileHandle.standardError.write(Data(
                    "[GoelDownloader] remote server listener failed on port \(portForLog): \(error)\n".utf8))
            case .waiting(let error):
                FileHandle.standardError.write(Data(
                    "[GoelDownloader] remote server waiting on port \(portForLog): \(error)\n".utf8))
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        newListener.start(queue: DispatchQueue(label: "goel.remote-server"))
        self.listener = newListener
        self.boundPort = port
        self.boundExposeLAN = exposeLAN
    }

    /// Stop listening and **wait** for the socket to be fully released. Awaiting the
    /// listener's `.cancelled` state (rather than firing `cancel()` and returning) is
    /// what lets a subsequent `start()` rebind the same port without EADDRINUSE — the
    /// cancel is asynchronous, so a fire-and-forget teardown leaves the port held.
    public func stop() async {
        generation += 1
        boundPort = nil
        boundExposeLAN = nil
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Resume exactly once, from whichever fires first — the listener's
            // terminal state or the backstop timer. A `@Sendable` one-shot keeps
            // this correct across the two concurrent callbacks.
            let once = OneShotResume(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: once.fire()
                default: break
                }
            }
            // Backstop: if the listener was already terminal, setting the handler
            // above won't re-fire it — don't hang teardown waiting for a state that
            // will never come.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { once.fire() }
            listener.cancel()
        }
    }

    // MARK: Connection handling

    /// Gate new connections behind the concurrency cap, then arm an idle
    /// timeout so a client that connects and sends nothing can't hold a slot
    /// (and its Task/queue) open forever.
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, _, error in
            timeout.cancel()
            guard let self, let data, error == nil, !data.isEmpty else {
                connection.cancel()
                Task { await self?.connectionClosed(connection) }
                return
            }
            Task {
                let request = RemoteRequest(raw: data)
                // Streaming routes hold the connection open and send
                // incrementally; everything else is one response and done.
                switch (request.method, request.path) {
                case ("GET", "/api/events"):
                    await self.serveEvents(connection, request)
                case ("GET", "/stream"):
                    await self.serveStream(connection, request)
                default:
                    let response = await self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                await self.connectionClosed(connection)
            }
        }
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
    private func serveEvents(_ connection: NWConnection, _ request: RemoteRequest) async {
        let router = self.router
        guard router.authorize(request, sessionAuthed: validSession(request)) else {
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
                let frame = router.eventFrame(for: await manager.snapshot)
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

    /// Handle one non-streaming request: cookie sessions and the login/logout
    /// endpoints live here; everything else delegates to the pure router with the
    /// session verdict folded in. Unauthenticated browser page-loads are bounced
    /// to `/login`; the `/api` surface returns 401 (handled by the router) so
    /// script clients get a clean status instead of an HTML redirect.
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

    /// True iff the request carries a live session cookie. Expired sessions are
    /// pruned on sight.
    private func validSession(_ request: RemoteRequest) -> Bool {
        guard let sid = request.cookie("goel_session"), let expiry = sessions[sid] else { return false }
        guard expiry > Date() else { sessions[sid] = nil; return false }
        return true
    }

    /// True iff a valid bearer/query token is present — used only to keep script
    /// clients from being redirected to the HTML login page.
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
        // Verify off the actor's executor: the salted-iterated hash is tens of
        // milliseconds of pure CPU, and running it inline would freeze the whole
        // server (SSE pushes, streaming, new connections) for its duration. The
        // detached task hops to a background executor; the actor suspends at the
        // `await` and services other work meanwhile.
        let hash = passwordHash
        let password = creds.password
        let passOK: Bool = hash.isEmpty
            ? false
            : await Task.detached { RemotePassword.verify(password, against: hash) }.value

        // Verify BEFORE consulting the lockout, so a correct credential ALWAYS
        // signs in. That way a flood of bad guesses can throttle further *failures*
        // but can never lock the legitimate user out (the earlier design let any
        // client hold everyone at 429 by failing 5× per window).
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

        // Failed attempt: apply the brute-force brake (throttles repeated failures).
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

    /// Accept credentials as a JSON body (the portal login) or as a classic
    /// `application/x-www-form-urlencoded` body (a no-JS fallback).
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

    // MARK: File streaming (watch while downloading / play remotely)

    /// `GET /stream?id=<task>` — serve a task's payload with Range support so
    /// media players (and the control page) can play it. Finished tasks stream
    /// the whole file; a sequential in-progress torrent streams its contiguous
    /// prefix (kept behind a safety margin). Multi-file torrents stream their
    /// largest wanted file once finished.
    private func serveStream(_ connection: NWConnection, _ request: RemoteRequest) async {
        func reject(_ status: String, _ message: String) async {
            _ = await send(connection, RemoteRouter.response(status: status, type: "text/plain",
                                                             body: Data("\(message)\n".utf8)))
            connection.cancel()
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

        // Clamp the requested range to the bytes that verifiably exist.
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

    // MARK: Stream planning (pure — kept here; referenced by the app + tests)

    /// What (and how much) of a task can be streamed right now, or nil.
    public struct StreamPlan {
        var path: String
        var totalBytes: Int64
        var availableBytes: Int64
    }

    public static func streamPlan(for task: DownloadTask) -> StreamPlan? {
        if task.status.hasData {
            // Finished payload: multi-file torrents stream their main file.
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
        // In flight: only a single-file sequential torrent has a contiguous,
        // provably-safe prefix. Stay a safety margin behind the write head.
        guard task.sequentialDownload == true, !task.isMultiFile,
              task.status == .downloading || task.status == .verifying,
              let total = task.totalBytes, total > 0 else { return nil }
        let margin: Int64 = 8 * 1024 * 1024
        let available = max(0, task.bytesDownloaded - margin)
        guard available > 0 else { return nil }
        return StreamPlan(path: task.savePath, totalBytes: total, availableBytes: available)
    }

    /// Parse `bytes=start-end` against what exists, clamping an open end.
    static func parseByteRange(_ header: String, available: Int64) -> (Int64, Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst("bytes=".count)
            .split(separator: ",")[0]   // first range only; we don't do multipart
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // Suffix form: last N bytes.
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return (max(0, available - n), available - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < available else { return nil }
        let end = Int64(parts[1]).map { min($0, available - 1) } ?? (available - 1)
        return (start, end)
    }

    /// Just enough MIME to make media players happy.
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

    /// Kept for source/test compatibility; the implementation now lives in
    /// ``RemoteRouter/constantTimeEquals(_:_:)``.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        RemoteRouter.constantTimeEquals(a, b)
    }
}

/// A thread-safe one-shot resume for a `CheckedContinuation` that may be signalled
/// by more than one concurrent callback (here: a listener's terminal state and a
/// timeout backstop). Resuming a continuation twice traps, so the first caller wins
/// and the rest are no-ops.
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
