import Foundation
import Network

/// The remote-access server: a minimal embedded HTTP endpoint exposing the
/// queue to a phone/other machine — a live web page plus a JSON API (list,
/// pause/resume, add). Token-authenticated; binds loopback-only unless the
/// user explicitly allows LAN access.
///
/// Deliberately small: one read per connection (our requests fit in a single
/// datagram), no TLS (LAN/loopback control channel), no streaming.
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
                let request = Request(raw: data)
                // Streaming routes hold the connection open and send
                // incrementally; everything else is one response and done.
                switch (request.method, request.path) {
                case ("GET", "/api/events"):
                    await self.serveEvents(connection, request)
                case ("GET", "/stream"):
                    await self.serveStream(connection, request)
                default:
                    let response = await self.route(request)
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
    private func serveEvents(_ connection: NWConnection, _ request: Request) async {
        guard authorized(request) else {
            _ = await send(connection, Self.response(status: "401 Unauthorized",
                                                     type: "text/plain",
                                                     body: Data("Invalid token\n".utf8)))
            connection.cancel()
            return
        }
        guard sseConnections < Self.maxSSEConnections else {
            _ = await send(connection, Self.response(status: "503 Service Unavailable",
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
                let rows = await manager.snapshot.map(TaskRow.init)
                let json = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
                var frame = Data("data: ".utf8)
                frame.append(json)
                frame.append(Data("\n\n".utf8))
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
    private func serveStream(_ connection: NWConnection, _ request: Request) async {
        func reject(_ status: String, _ message: String) async {
            _ = await send(connection, Self.response(status: status, type: "text/plain",
                                                     body: Data("\(message)\n".utf8)))
            connection.cancel()
        }
        guard authorized(request) else { return await reject("401 Unauthorized", "Invalid token") }
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

    /// A parsed-enough HTTP request: method, path, query, headers, body.
    private struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()

        init(raw: Data) {
            guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return }
            body = raw.suffix(from: headerEnd.upperBound)
            guard let head = String(data: raw.prefix(upTo: headerEnd.lowerBound), encoding: .utf8)
            else { return }
            let lines = head.components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ") ?? []
            if request.count >= 2 {
                method = String(request[0])
                let target = String(request[1])
                let parts = target.split(separator: "?", maxSplits: 1)
                path = String(parts.first ?? "")
                if parts.count == 2 {
                    for pair in parts[1].split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        guard let key = kv.first else { continue }
                        query[String(key)] = kv.count == 2
                            ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
                    }
                }
            }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
    }

    // MARK: Routing

    private func route(_ request: Request) async -> Data {
        guard authorized(request) else {
            return Self.response(status: "401 Unauthorized", type: "text/plain",
                                 body: Data("Missing or invalid token. Open /?token=<your token>.\n".utf8))
        }
        guard let manager else {
            return Self.response(status: "503 Service Unavailable", type: "text/plain",
                                 body: Data("Shutting down\n".utf8))
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return Self.response(status: "200 OK", type: "text/html; charset=utf-8",
                                 body: Data(Self.page(token: token).utf8))

        case ("GET", "/api/tasks"):
            let rows = await manager.snapshot.map(TaskRow.init)
            let data = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
            return Self.response(status: "200 OK", type: "application/json", body: data)

        case ("POST", "/api/pause-all"):
            await manager.pauseAll()
            return Self.ok()

        case ("POST", "/api/resume-all"):
            await manager.resumeAll()
            return Self.ok()

        case ("POST", "/api/pause"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)) else { return Self.badRequest() }
            await manager.pause(id)
            return Self.ok()

        case ("POST", "/api/resume"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)) else { return Self.badRequest() }
            await manager.resume(id)
            return Self.ok()

        case ("POST", "/api/add"):
            guard let payload = try? JSONDecoder().decode(AddPayload.self, from: request.body),
                  let source = DownloadSource.parse(payload.url) else { return Self.badRequest() }
            await manager.add(source: source)
            return Self.ok()

        default:
            return Self.response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    private func authorized(_ request: Request) -> Bool {
        guard !token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           Self.constantTimeEquals(header, "Bearer \(token)") { return true }
        guard let query = request.query["token"] else { return false }
        return Self.constantTimeEquals(query, token)
    }

    /// Length-leaking-only comparison: every byte is examined regardless of
    /// where the first mismatch occurs, so response timing can't be used to
    /// guess the token prefix-by-prefix.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

    private struct AddPayload: Decodable { var url: String }

    /// The wire representation of one task.
    private struct TaskRow: Encodable {
        var id: String
        var name: String
        var status: String
        var progress: Double
        var downSpeed: Double
        var upSpeed: Double
        var totalBytes: Int64?
        var streamable: Bool

        init(_ task: DownloadTask) {
            id = task.id.uuidString
            name = task.name
            status = task.status.displayName
            progress = task.fractionCompleted
            downSpeed = task.downloadSpeed
            upSpeed = task.uploadSpeed
            totalBytes = task.totalBytes
            streamable = RemoteControlServer.streamPlan(for: task) != nil
        }
    }

    // MARK: Response building

    private static func ok() -> Data {
        response(status: "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    private static func badRequest() -> Data {
        response(status: "400 Bad Request", type: "text/plain", body: Data("Bad request\n".utf8))
    }

    private static func response(status: String, type: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // Defense-in-depth for the control page: inline script/style are ours
        // by construction, network access is same-origin only, no framing.
        head += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; "
        head += "style-src 'unsafe-inline'; connect-src 'self'\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// The single-file control page: polls /api/tasks, renders rows, offers
    /// pause/resume and an add box. The token rides along in each request.
    private static func page(token: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>GoelDownloader</title>
        <style>
        body{font:14px -apple-system,system-ui,sans-serif;margin:0;background:#111;color:#eee}
        header{padding:14px 16px;background:#1b1b1f;display:flex;gap:8px;align-items:center}
        h1{font-size:15px;margin:0 auto 0 0}
        button{background:#2f6fed;color:#fff;border:0;border-radius:6px;padding:6px 10px;cursor:pointer}
        .task{padding:10px 16px;border-bottom:1px solid #222}
        .name{display:flex;justify-content:space-between;gap:8px}
        .meta{color:#999;font-size:12px;margin-top:2px;display:flex;justify-content:space-between}
        .bar{height:4px;background:#333;border-radius:2px;margin-top:6px}
        .fill{height:4px;background:#2f6fed;border-radius:2px}
        form{display:flex;gap:8px;padding:12px 16px;background:#1b1b1f}
        input{flex:1;background:#111;color:#eee;border:1px solid #333;border-radius:6px;padding:6px 8px}
        .play{color:#2f6fed;text-decoration:none;font-size:16px;vertical-align:middle;margin-right:4px}
        </style></head><body>
        <header><h1>GoelDownloader</h1>
        <button onclick="act('pause-all')">Pause all</button>
        <button onclick="act('resume-all')">Start all</button></header>
        <form onsubmit="add(event)"><input id="u" placeholder="URL or magnet…">
        <button>Add</button></form>
        <div id="list"></div>
        <script>
        const T=\(jsString(token));
        const speed=b=>b>1e6?(b/1e6).toFixed(1)+' MB/s':b>1e3?(b/1e3).toFixed(0)+' kB/s':'';
        function render(tasks){
          document.getElementById('list').innerHTML=tasks.map(t=>`
            <div class="task"><div class="name"><span>${esc(t.name)}</span><span>
            ${t.streamable?`<a class="play" href="/stream?id=${t.id}&token=${encodeURIComponent(T)}" target="_blank">▶</a> `:''}
            <button onclick="act('${t.status==='Paused'?'resume':'pause'}','${t.id}')">
            ${t.status==='Paused'?'Resume':'Pause'}</button></span></div>
            <div class="meta"><span>${t.status}</span><span>${speed(t.downSpeed)}</span></div>
            <div class="bar"><div class="fill" style="width:${(t.progress*100).toFixed(1)}%"></div></div>
            </div>`).join('');
        }
        async function tick(){
          try{
            const r=await fetch('/api/tasks?token='+encodeURIComponent(T));
            render(await r.json());
          }catch(e){}
        }
        function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
        async function act(a,id){
          await fetch('/api/'+a+'?token='+encodeURIComponent(T)+(id?'&id='+id:''),{method:'POST'});
          tick();
        }
        async function add(e){
          e.preventDefault();
          const u=document.getElementById('u');
          if(!u.value)return;
          await fetch('/api/add?token='+encodeURIComponent(T),{method:'POST',
            headers:{'Content-Type':'application/json'},body:JSON.stringify({url:u.value})});
          u.value='';tick();
        }
        // Live push via SSE when available; fall back to polling otherwise.
        let live=false;
        try{
          const es=new EventSource('/api/events?token='+encodeURIComponent(T));
          es.onmessage=e=>{live=true;render(JSON.parse(e.data))};
          es.onerror=()=>{live=false};
        }catch(e){}
        tick();setInterval(()=>{if(!live)tick()},2000);
        </script></body></html>
        """
    }

    /// Encode a value as a JS string literal (handles quotes/backslashes).
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode([value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
