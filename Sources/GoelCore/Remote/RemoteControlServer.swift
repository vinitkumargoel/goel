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
    private var token = ""

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

    /// A router bound to the current backend + token, rebuilt per use (cheap).
    private var router: RemoteRouter { RemoteRouter(backend: manager, token: token) }

    /// Start (or restart) listening. `allowLAN: false` binds 127.0.0.1 only.
    ///
    /// The port must be specified exactly once: through `requiredLocalEndpoint`
    /// for the loopback-only bind, or through the listener's `on:` port for the
    /// LAN bind. Passing both is a conflicting specification NWListener rejects.
    public func start(port: UInt16, token: String, allowLAN: Bool) {
        stop()
        self.token = token
        let listenPort = NWEndpoint.Port(rawValue: port) ?? 8899
        let listener: NWListener?
        if allowLAN {
            listener = try? NWListener(using: .tcp, on: listenPort)
        } else {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: listenPort)
            listener = try? NWListener(using: parameters)
        }
        guard let listener else {
            FileHandle.standardError.write(Data("[GoelDownloader] remote server failed to bind port \(port)\n".utf8))
            return
        }
        // Advertise over Bonjour only when the user opted into LAN access — a
        // loopback-only server has nothing to announce to the network.
        if allowLAN {
            listener.service = NWListener.Service(name: "GoelDownloader", type: "_http._tcp")
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "goel.remote-server"))
        self.listener = listener
    }

    public func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
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
                    let response = await self.router.handle(request)
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
        guard router.authorize(request) else {
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
        guard router.authorize(request) else { return await reject("401 Unauthorized", "Invalid token") }
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
