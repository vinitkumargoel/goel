import Foundation

/// The pure decision core of the remote-access server: it maps a parsed
/// ``RemoteRequest`` to a fully-formed HTTP response, with **no socket and no
/// FileHandle**. Everything deterministic — request parsing, the route table,
/// auth (constant-time), the JSON API, and the embedded control page — lives here
/// and is unit-testable with an in-memory ``RemoteBackend``.
///
/// ``RemoteControlServer`` keeps the I/O (the `NWListener`, the SSE loop, byte-range
/// streaming) **and** the stateful pieces auth can't be pure about: the session
/// store and the login/logout endpoints. It tells the router, per request, whether
/// a valid session cookie was presented via `sessionAuthed`; the router folds that
/// together with the bearer/query token to decide access.
public struct RemoteRouter: Sendable {

    /// Everything the router needs to render and gate a request, snapshotted from
    /// ``AppSettings`` when the server (re)starts.
    public struct Config: Sendable {
        /// Bearer/query token for scripts and the browser extension.
        public var token: String
        /// When false, the portal is open (no login) — only sane on a loopback bind.
        public var requireAuth: Bool
        /// Serve view/stream only; every mutating route returns 403.
        public var readOnly: Bool
        /// The portal's default theme token (e.g. `"frost-dark"`). A browser may
        /// override it locally; this is the first-load default.
        public var theme: String
        /// Login username, echoed to the portal so it can greet the user.
        public var username: String

        public init(token: String, requireAuth: Bool = true, readOnly: Bool = false,
                    theme: String = "frost-dark", username: String = "admin") {
            self.token = token
            self.requireAuth = requireAuth
            self.readOnly = readOnly
            self.theme = theme
            self.username = username
        }
    }

    /// The narrow seam onto the scheduler — exactly the calls the remote API makes.
    /// ``DownloadManager`` conforms with a tiny adapter (see below).
    public let backend: RemoteBackend?
    public let config: Config

    /// Convenience token accessor (several sites and tests still think in "token").
    public var token: String { config.token }

    public init(backend: RemoteBackend?, config: Config) {
        self.backend = backend
        self.config = config
    }

    /// Back-compat init used by tests and any token-only caller. Defaults to
    /// `requireAuth: true` so a non-empty token still gates every request.
    public init(backend: RemoteBackend?, token: String) {
        self.init(backend: backend, config: Config(token: token))
    }

    /// Map a request to the exact HTTP response bytes for every non-streaming,
    /// non-login route. `sessionAuthed` is the server's verdict on the session
    /// cookie; login/logout and the cookie itself are handled by the server.
    public func handle(_ request: RemoteRequest, sessionAuthed: Bool = false) async -> Data {
        guard authorize(request, sessionAuthed: sessionAuthed) else {
            return Self.response(status: "401 Unauthorized", type: "text/plain",
                                 body: Data("Not signed in. Open / to log in, or pass ?token=<token>.\n".utf8))
        }
        guard let backend else {
            return Self.response(status: "503 Service Unavailable", type: "text/plain",
                                 body: Data("Shutting down\n".utf8))
        }

        // Read-only mode disables every state change (all mutations are POSTs).
        if config.readOnly, request.method == "POST" {
            return Self.forbidden("Read-only mode — changes are disabled from the web.")
        }

        switch (request.method, request.path) {

        // MARK: Pages & meta
        case ("GET", "/"):
            return Self.response(status: "200 OK", type: "text/html; charset=utf-8",
                                 body: Data(Self.page(config: config).utf8))

        case ("GET", "/api/config"):
            return Self.json(ConfigRow(username: config.username, readOnly: config.readOnly,
                                       requireAuth: config.requireAuth, theme: config.theme))

        // MARK: Reads
        case ("GET", "/api/tasks"):
            let rows = await backend.taskSnapshot().map(TaskRow.init)
            return Self.json(rows)

        case ("GET", "/api/task"):
            guard let id = queryID(request) else { return Self.badRequest() }
            guard let task = await backend.task(id) else { return Self.notFound() }
            return Self.json(TaskDetail(task))

        case ("GET", "/api/history"):
            let rows = await backend.history(limit: 500).map(HistoryRow.init)
            return Self.json(rows)

        // MARK: Queue mutations
        case ("POST", "/api/pause-all"):
            await backend.pauseAll(); return Self.ok()

        case ("POST", "/api/resume-all"):
            await backend.resumeAll(); return Self.ok()

        case ("POST", "/api/pause"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.pause(id); return Self.ok()

        case ("POST", "/api/resume"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.resume(id); return Self.ok()

        case ("POST", "/api/retry"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.retry(id); return Self.ok()

        case ("POST", "/api/recheck"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.forceRecheck(id); return Self.ok()

        case ("POST", "/api/sequential"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.setSequential(boolQuery(request, "on"), task: id); return Self.ok()

        case ("POST", "/api/remove"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.remove(id, deleteData: boolQuery(request, "data")); return Self.ok()

        case ("POST", "/api/file-priority"):
            guard let id = queryID(request),
                  let file = request.query["file"].flatMap(Int.init) else { return Self.badRequest() }
            await backend.setFilePriority(Self.priority(request.query["prio"]), fileID: file, task: id)
            return Self.ok()

        case ("POST", "/api/add"):
            guard let payload = try? JSONDecoder().decode(AddPayload.self, from: request.body)
            else { return Self.badRequest() }
            let folder = payload.folder?.trimmingCharacters(in: .whitespaces)
            let priority = Self.priority(payload.priority)
            let paused = payload.paused ?? false
            let sources = payload.url
                .split(whereSeparator: \.isNewline)
                .compactMap { DownloadSource.parse(String($0).trimmingCharacters(in: .whitespaces)) }
            guard !sources.isEmpty else { return Self.badRequest() }
            for source in sources {
                await backend.remoteAdd(source: source,
                                        saveDirectory: (folder?.isEmpty == false) ? folder : nil,
                                        priority: priority, startPaused: paused)
            }
            return Self.json(CountRow(added: sources.count))

        // MARK: History mutations
        case ("POST", "/api/history-clear"):
            await backend.clearHistory(); return Self.ok()

        case ("POST", "/api/history-remove"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.removeHistoryEntry(id); return Self.ok()

        default:
            return Self.response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    /// Access check shared by the JSON API and the streaming loops. A valid
    /// session cookie (decided by the server) always passes; otherwise, an open
    /// portal (`requireAuth == false`) passes, and finally a matching bearer/query
    /// token passes — the path scripts use.
    public func authorize(_ request: RemoteRequest, sessionAuthed: Bool = false) -> Bool {
        if sessionAuthed { return true }
        if !config.requireAuth { return true }
        guard !config.token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           Self.constantTimeEquals(header, "Bearer \(config.token)") { return true }
        guard let query = request.query["token"] else { return false }
        return Self.constantTimeEquals(query, config.token)
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
    /// token/hash prefix-by-prefix.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

    // MARK: Query helpers

    private func queryID(_ request: RemoteRequest) -> UUID? {
        request.query["id"].flatMap(UUID.init(uuidString:))
    }

    private func boolQuery(_ request: RemoteRequest, _ key: String) -> Bool {
        Self.truthy(request.query[key])
    }

    static func truthy(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    static func priority(_ value: String?) -> FilePriority {
        switch value?.lowercased() {
        case "skip": return .skip
        case "low": return .low
        case "high": return .high
        default: return .normal
        }
    }

    // MARK: Response building

    static func ok() -> Data {
        response(status: "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    static func badRequest() -> Data {
        response(status: "400 Bad Request", type: "text/plain", body: Data("Bad request\n".utf8))
    }

    static func notFound() -> Data {
        response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
    }

    static func forbidden(_ message: String) -> Data {
        response(status: "403 Forbidden", type: "text/plain", body: Data("\(message)\n".utf8))
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        let body = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        return response(status: "200 OK", type: "application/json", body: body)
    }

    static func response(status: String, type: String, body: Data,
                         extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // Defense-in-depth for the control page: inline script/style are ours by
        // construction; allow same-origin fetch/SSE, streamed media, and the
        // inline SVG/data: favicon; forms post same-origin; nothing may frame us.
        head += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; "
        head += "style-src 'unsafe-inline'; img-src 'self' data:; media-src 'self'; "
        head += "connect-src 'self'; form-action 'self'; base-uri 'none'\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    // MARK: Wire models

    private struct AddPayload: Decodable {
        var url: String
        var folder: String?
        var priority: String?
        var paused: Bool?
    }
    private struct CountRow: Encodable { var added: Int }
    private struct ConfigRow: Encodable {
        var username: String
        var readOnly: Bool
        var requireAuth: Bool
        var theme: String
        var appName = "Goel°"
    }

    /// Compact per-task row for the live list.
    struct TaskRow: Encodable {
        var id: String
        var name: String
        var status: String        // display name ("Downloading")
        var statusToken: String   // stable token ("downloading")
        var kind: String          // "http" | "torrent" | "hls" | "ftp" | "sftp"
        var progress: Double
        var downSpeed: Double
        var upSpeed: Double
        var totalBytes: Int64?
        var doneBytes: Int64
        var upBytes: Int64
        var ratio: Double
        var seeds: Int?
        var conns: Int
        var addedAt: Double
        var etaSeconds: Double?
        var error: String?
        var source: String
        var multiFile: Bool
        var fileCount: Int
        var streamable: Bool

        init(_ task: DownloadTask) {
            id = task.id.uuidString
            name = task.name
            status = task.status.displayName
            statusToken = RemoteRouter.statusToken(task.status)
            kind = task.kind.rawValue
            progress = task.fractionCompleted
            downSpeed = task.downloadSpeed
            upSpeed = task.uploadSpeed
            totalBytes = task.totalBytes
            doneBytes = task.bytesDownloaded
            upBytes = task.bytesUploaded
            ratio = task.shareRatio
            seeds = task.seedCount
            conns = task.connectionCount
            addedAt = task.addedAt.timeIntervalSince1970
            etaSeconds = task.estimatedTimeRemaining
            error = RemoteRouter.errorMessage(task.status)
            source = task.source.locator
            multiFile = task.isMultiFile
            fileCount = task.files.count
            streamable = RemoteControlServer.streamPlan(for: task) != nil
        }
    }

    /// The full detail for the selected task (files, trackers, peers, pieces).
    struct TaskDetail: Encodable {
        var row: TaskRow
        var savePath: String
        var sequential: Bool
        var infoHash: String?
        var files: [FileRow]
        var trackers: [TrackerRow]
        var connections: [ConnRow]
        var pieces: [Double]
        var server: String?
        var mimeType: String?

        init(_ task: DownloadTask) {
            row = TaskRow(task)
            savePath = task.savePath
            sequential = task.sequentialDownload ?? false
            infoHash = task.infoHash
            files = task.files.map(FileRow.init)
            trackers = (task.trackers ?? []).map(TrackerRow.init)
            connections = (task.connections ?? []).map(ConnRow.init)
            pieces = task.pieceAvailability ?? []
            server = task.remoteInfo?.server
            mimeType = task.remoteInfo?.mimeType
        }
    }

    struct FileRow: Encodable {
        var id: Int
        var name: String
        var size: Int64
        var done: Int64
        var progress: Double
        var priority: String
        init(_ f: TransferFile) {
            id = f.id
            name = f.path
            size = f.length
            done = f.bytesCompleted
            progress = f.fractionCompleted
            priority = RemoteRouter.priorityToken(f.priority)
        }
    }

    struct TrackerRow: Encodable {
        var url: String
        var host: String
        var tier: Int
        var status: String
        var seeds: Int?
        var leeches: Int?
        var message: String
        init(_ t: TorrentTracker) {
            url = t.url
            host = t.host
            tier = t.tier
            status = t.statusLabel
            seeds = t.seeds
            leeches = t.leeches
            message = t.message
        }
    }

    struct ConnRow: Encodable {
        var id: String
        var label: String
        var detail: String
        var down: Double
        var up: Double
        var progress: Double
        init(_ c: TaskConnection) {
            id = c.id
            label = c.label
            detail = c.detail
            down = c.downloadSpeed
            up = c.uploadSpeed
            progress = c.progress
        }
    }

    struct HistoryRow: Encodable {
        var id: String
        var name: String
        var kind: String
        var totalBytes: Int64?
        var savePath: String
        var completedAt: Double
        var source: String
        init(_ h: HistoryEntry) {
            id = h.id.uuidString
            name = h.name
            kind = h.kind.rawValue
            totalBytes = h.totalBytes
            savePath = h.savePath
            completedAt = h.completedAt.timeIntervalSince1970
            source = h.locator
        }
    }

    // MARK: Enum → token helpers

    static func statusToken(_ status: DownloadStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .requestingMetadata: return "metadata"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .paused: return "paused"
        case .seeding: return "seeding"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }

    static func priorityToken(_ priority: FilePriority) -> String {
        switch priority {
        case .skip: return "skip"
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        }
    }

    static func errorMessage(_ status: DownloadStatus) -> String? {
        if case .failed(let error) = status { return error.message }
        return nil
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

    /// Value of one cookie from the `Cookie:` header, or `nil`. Cookies are
    /// `name=value` pairs separated by `; `.
    public func cookie(_ name: String) -> String? {
        guard let raw = headers["cookie"] else { return nil }
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0].trimmingCharacters(in: .whitespaces) == name {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

// MARK: - Backend port

/// The set of scheduler calls the remote API needs. ``DownloadManager`` conforms
/// via the adapter below; tests inject an in-memory fake.
public protocol RemoteBackend: AnyObject, Sendable {
    func taskSnapshot() async -> [DownloadTask]
    func task(_ id: UUID) async -> DownloadTask?
    func pauseAll() async
    func resumeAll() async
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func retry(_ id: UUID) async
    func remove(_ id: UUID, deleteData: Bool) async
    func forceRecheck(_ id: UUID) async
    func setSequential(_ sequential: Bool, task id: UUID) async
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async
    func remoteAdd(source: DownloadSource) async
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async
    func history(limit: Int) async -> [HistoryEntry]
    func removeHistoryEntry(_ id: UUID) async
    func clearHistory() async
}

extension DownloadManager: RemoteBackend {
    /// `snapshot` is a property and the rich `add(source:…)` returns a task — the
    /// port needs plain methods. `pause`/`resume`/`retry`/`remove`/`forceRecheck`/
    /// `setSequential`/`setFilePriority`/`history`/`removeHistoryEntry`/`clearHistory`
    /// already match the actor's own methods (an actor's isolated method witnesses
    /// an `async` requirement), so only the two below need adapting.
    public func taskSnapshot() async -> [DownloadTask] { snapshot }
    public func remoteAdd(source: DownloadSource) async { _ = add(source: source, saveDirectory: nil) }
    public func remoteAdd(source: DownloadSource, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async {
        _ = add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
                priority: priority, startPaused: startPaused)
    }

    /// Constrain a remote-supplied save directory to the configured downloads
    /// root. The remote portal is a network-facing surface: without this, an
    /// (authenticated) client could set `folder` to an arbitrary path such as
    /// `~/Library/LaunchAgents` or `/etc/cron.d` and drop an attacker-chosen file
    /// into an auto-run location. A folder outside the root is refused (→ nil, so
    /// the safe per-source default is used instead of the client's value).
    func remoteSaveDirectory(_ folder: String?) -> String? {
        guard let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        let root = settings.defaultSaveDirectory
        if PathSafety.isContained(folder, within: root) { return folder }
        FileHandle.standardError.write(Data(
            "[GoelDownloader] remote add: rejecting out-of-root save folder; using default\n".utf8))
        return nil
    }
}
