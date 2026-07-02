import Foundation

/// The pure decision core of the remote-access server: it maps a parsed
/// ``RemoteRequest`` to a fully-formed HTTP response, with **no socket and no
/// FileHandle**. Everything deterministic — request parsing, the route table,
/// token auth (constant-time), the JSON API, and the embedded control page —
/// lives here and is unit-testable with an in-memory ``RemoteBackend``.
///
/// ``RemoteControlServer`` keeps only the I/O: the `NWListener`, the SSE loop, and
/// the byte-range file streaming, delegating every decision (auth, routing, the
/// event frame) to this router.
public struct RemoteRouter: Sendable {

    /// The narrow seam onto the scheduler — exactly the calls the remote API makes.
    /// ``DownloadManager`` conforms with a tiny adapter (see below).
    public let backend: RemoteBackend?
    public let token: String

    public init(backend: RemoteBackend?, token: String) {
        self.backend = backend
        self.token = token
    }

    /// The entry point: map a request to the exact HTTP response bytes for every
    /// non-streaming route. (`/api/events` and `/stream` are I/O loops the server
    /// runs, using ``authorize(_:)`` and ``eventFrame(for:)`` from here.)
    public func handle(_ request: RemoteRequest) async -> Data {
        guard authorize(request) else {
            return Self.response(status: "401 Unauthorized", type: "text/plain",
                                 body: Data("Missing or invalid token. Open /?token=<your token>.\n".utf8))
        }
        guard let backend else {
            return Self.response(status: "503 Service Unavailable", type: "text/plain",
                                 body: Data("Shutting down\n".utf8))
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return Self.response(status: "200 OK", type: "text/html; charset=utf-8",
                                 body: Data(Self.page(token: token).utf8))

        case ("GET", "/api/tasks"):
            let rows = await backend.taskSnapshot().map(TaskRow.init)
            let data = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
            return Self.response(status: "200 OK", type: "application/json", body: data)

        case ("POST", "/api/pause-all"):
            await backend.pauseAll()
            return Self.ok()

        case ("POST", "/api/resume-all"):
            await backend.resumeAll()
            return Self.ok()

        case ("POST", "/api/pause"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)) else { return Self.badRequest() }
            await backend.pause(id)
            return Self.ok()

        case ("POST", "/api/resume"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)) else { return Self.badRequest() }
            await backend.resume(id)
            return Self.ok()

        case ("POST", "/api/add"):
            guard let payload = try? JSONDecoder().decode(AddPayload.self, from: request.body),
                  let source = DownloadSource.parse(payload.url) else { return Self.badRequest() }
            await backend.remoteAdd(source: source)
            return Self.ok()

        default:
            return Self.response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    /// Token check shared by the JSON API and the streaming loops.
    public func authorize(_ request: RemoteRequest) -> Bool {
        guard !token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           Self.constantTimeEquals(header, "Bearer \(token)") { return true }
        guard let query = request.query["token"] else { return false }
        return Self.constantTimeEquals(query, token)
    }

    /// One SSE frame (`data: <json>\n\n`) for the live event stream.
    public func eventFrame(for tasks: [DownloadTask]) -> Data {
        let rows = tasks.map(TaskRow.init)
        let json = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        return frame
    }

    /// Length-leaking-only comparison: every byte is examined regardless of where
    /// the first mismatch occurs, so response timing can't be used to guess the
    /// token prefix-by-prefix.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

    // MARK: Response building

    static func ok() -> Data {
        response(status: "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    static func badRequest() -> Data {
        response(status: "400 Bad Request", type: "text/plain", body: Data("Bad request\n".utf8))
    }

    static func response(status: String, type: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // Defense-in-depth for the control page: inline script/style are ours by
        // construction, network access is same-origin only, no framing.
        head += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; "
        head += "style-src 'unsafe-inline'; connect-src 'self'\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private struct AddPayload: Decodable { var url: String }

    /// The wire representation of one task.
    struct TaskRow: Encodable {
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

    /// The single-file control page: polls /api/tasks, renders rows, offers
    /// pause/resume and an add box. The token rides along in each request.
    static func page(token: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Goel°</title>
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
        <header><h1>Goel°</h1>
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

// MARK: - Request parsing

/// A parsed-enough HTTP request: method, path, query, headers, body. Built from
/// the raw connection bytes, so parsing is testable without a socket.
public struct RemoteRequest: Sendable {
    public var method = ""
    public var path = ""
    public var query: [String: String] = [:]
    public var headers: [String: String] = [:]
    public var body = Data()

    public init(raw: Data) {
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

// MARK: - Backend port

/// The narrow set of scheduler calls the remote API needs. ``DownloadManager``
/// conforms via the adapter below; tests inject an in-memory fake.
public protocol RemoteBackend: AnyObject, Sendable {
    func taskSnapshot() async -> [DownloadTask]
    func task(_ id: UUID) async -> DownloadTask?
    func pauseAll() async
    func resumeAll() async
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func remoteAdd(source: DownloadSource) async
}

extension DownloadManager: RemoteBackend {
    /// `snapshot` is a property, and the rich `add(source:…)` returns a task — the
    /// port needs plain methods. `task`/`pause`/`resume`/`pauseAll`/`resumeAll`
    /// already match (an actor's isolated method witnesses an `async` requirement).
    public func taskSnapshot() async -> [DownloadTask] { snapshot }
    public func remoteAdd(source: DownloadSource) async { _ = add(source: source, saveDirectory: nil) }
}
