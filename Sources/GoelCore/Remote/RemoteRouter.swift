import Foundation

public struct RemoteRouter: Sendable {

    public struct Config: Sendable {
        public var token: String
        /// When false the portal is open (no login) — only sane on a loopback bind.
        public var requireAuth: Bool
        public var readOnly: Bool
        public var theme: String
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

    public let backend: RemoteBackend?
    public let config: Config

    public var token: String { config.token }

    public init(backend: RemoteBackend?, config: Config) {
        self.backend = backend
        self.config = config
    }

    /// Must default to `requireAuth: true`, or a token-only caller gets an ungated router.
    public init(backend: RemoteBackend?, token: String) {
        self.init(backend: backend, config: Config(token: token))
    }

    public func handle(_ request: RemoteRequest, sessionAuthed: Bool = false) async -> Data {
        guard authorize(request, sessionAuthed: sessionAuthed) else {
            return Self.response(status: "401 Unauthorized", type: "text/plain",
                                 body: Data("Not signed in. Open / to log in, or pass ?token=<token>.\n".utf8))
        }
        guard let backend else {
            return Self.response(status: "503 Service Unavailable", type: "text/plain",
                                 body: Data("Shutting down\n".utf8))
        }

        // SameSite=Strict covers sessions, but an open portal authorises everyone — refuse foreign Origins.
        guard Self.crossSiteWriteAllowed(request) else {
            return Self.forbidden("Cross-site request refused.")
        }

        // Read-only relies on every mutation being a POST.
        if config.readOnly, request.method == "POST" {
            return Self.forbidden("Read-only mode — changes are disabled from the web.")
        }

        switch (request.method, request.path) {

        case ("GET", "/"):
            return Self.response(status: "200 OK", type: "text/html; charset=utf-8",
                                 body: Data(Self.page(config: config).utf8))

        // Assets are also served ahead of the auth gate — see `staticAsset`.
        case ("GET", let path) where path.hasPrefix(Self.assetPrefix):
            return Self.staticAsset(path: path) ?? Self.notFound()

        case ("GET", "/api/config"):
            return Self.json(ConfigRow(username: config.username, readOnly: config.readOnly,
                                       requireAuth: config.requireAuth, theme: config.theme))

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
            // Refuse an unwritable folder rather than quietly saving elsewhere.
            if let folder, !folder.isEmpty, await backend.remoteSaveDirectoryAllowed(folder) == false {
                return Self.forbidden("That save folder cannot be written to — it does not exist, is not a folder, or this user has no permission for it.")
            }
            let priority = Self.priority(payload.priority)
            let paused = payload.paused ?? false
            // Refuse a malformed spec rather than silently downgrading to `auto`.
            var network: NetworkSelection?
            if let raw = payload.network, !raw.isEmpty {
                guard let parsed = NetworkSelection(spec: raw) else {
                    return Self.badRequest()
                }
                network = parsed
            }
            let sources = payload.url
                .split(whereSeparator: \.isNewline)
                .compactMap { DownloadSource.parse(String($0).trimmingCharacters(in: .whitespaces)) }
            guard !sources.isEmpty else { return Self.badRequest() }
            // SSRF guard, by resolved address not spelling: no steering this host at loopback/metadata.
            var refused = 0
            var allowed: [DownloadSource] = []
            for source in sources {
                guard let url = source.fetchTargetURL else { allowed.append(source); continue }
                if await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(url) {
                    allowed.append(source)
                    continue
                }
                GoelLog.remote.error("Remote add: refusing an internal-network target",
                                     .state(url.scheme ?? "", label: "scheme"))
                refused += 1
            }
            guard !allowed.isEmpty else {
                return Self.forbidden("That address is on this machine or an internal network range — refused.")
            }
            for source in allowed {
                await backend.remoteAdd(source: source,
                                        saveDirectory: (folder?.isEmpty == false) ? folder : nil,
                                        priority: priority, startPaused: paused,
                                        network: network)
            }
            return Self.json(CountRow(added: allowed.count, refused: refused))

        case ("GET", "/api/folders"):
            guard let listing = await backend.folderListing(request.query["path"]) else {
                return Self.notFound("That folder does not exist, or is not a folder.")
            }
            return Self.json(listing)

        case ("POST", "/api/folder"):
            guard let payload = try? JSONDecoder().decode(NewFolderPayload.self, from: request.body)
            else { return Self.badRequest() }
            // Reject, never sanitise: `PathSafety.sanitizedName` would repair a typed "../" into "download".
            let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isPlainFolderName(name) else {
                return Self.badRequest("A folder name cannot be empty, contain “/”, or begin with a dot.")
            }
            guard let created = await backend.createFolder(named: name, in: payload.parent) else {
                return Self.forbidden(
                    "Could not create that folder — this user may not have permission to write there.")
            }
            return Self.json(NewFolderRow(path: created))

        case ("GET", "/api/network"):
            return Self.json(await backend.networkState())

        case ("POST", "/api/network"):
            guard let payload = try? JSONDecoder().decode(AggregationPayload.self, from: request.body)
            else { return Self.badRequest() }
            if let bad = payload.adapters?.first(where: { !NetworkSelection.isValidInterfaceName($0) }) {
                return Self.badRequest("‘\(bad)’ is not an interface name.")
            }
            if let streams = payload.streams, !(1...8).contains(streams) {
                return Self.badRequest("Connections per interface must be 1–8.")
            }
            await backend.updateAggregation(enabled: payload.aggregation,
                                            adapterIds: payload.adapters,
                                            streams: payload.streams)
            return Self.json(await backend.networkState())

        case ("POST", "/api/history-remove"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.removeHistoryEntry(id); return Self.ok()

        default:
            return Self.response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    static let assetPrefix = "/assets/"

    /// Deliberately ahead of the auth gate (the login page needs styles); dict lookup, so no traversal.
    static func staticAsset(path: String) -> Data? {
        guard path.hasPrefix(assetPrefix) else { return nil }
        let name = String(path.dropFirst(assetPrefix.count))
        guard let asset = PortalBundle.assets[name] else { return notFound() }
        return response(status: "200 OK", type: asset.mime, body: Data(asset.body.utf8),
                        extraHeaders: ["Cache-Control": "public, max-age=31536000, immutable"])
    }

    /// Auth order: session cookie, then open portal, then constant-time bearer/query token.
    public func authorize(_ request: RemoteRequest, sessionAuthed: Bool = false) -> Bool {
        if sessionAuthed { return true }
        if !config.requireAuth { return true }
        guard !config.token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           Self.constantTimeEquals(header, "Bearer \(config.token)") { return true }
        guard let query = request.query["token"] else { return false }
        return Self.constantTimeEquals(query, config.token)
    }

    /// Absent `Origin` = no browser; foreign = cross-site write. `X-Forwarded-Host` counts (proxies keep `Host`).
    static func crossSiteWriteAllowed(_ request: RemoteRequest) -> Bool {
        guard request.method == "POST", let origin = request.headers["origin"] else { return true }
        return originMatchesHost(origin, host: request.headers["host"])
            || originMatchesHost(origin, host: request.headers["x-forwarded-host"])
    }

    /// Scheme is deliberately ignored: `Host` carries none and the socket speaks only one scheme.
    static func originMatchesHost(_ origin: String, host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty,
              let url = URL(string: origin.trimmingCharacters(in: .whitespaces)),
              let originHost = url.host?.lowercased() else { return false }
        if let port = url.port { return "\(originHost):\(port)" == host }
        return originHost == host
    }

    public func eventFrame(for tasks: [DownloadTask]) -> Data? {
        let rows = tasks.map(TaskRow.init)
        guard let json = try? JSONEncoder().encode(rows) else { return nil }
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        return frame
    }

    /// Every byte is examined regardless of mismatch — response timing must not leak the token prefix.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

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

    /// One path component only — deliberately stricter than ``PathSafety/sanitizedName(_:fallback:)``.
    static func isPlainFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 240 else { return false }
        guard !trimmed.hasPrefix(".") else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        // Control characters and NUL would produce a path the user cannot read back or re-select.
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }

    static func priority(_ value: String?) -> FilePriority {
        switch value?.lowercased() {
        case "skip": return .skip
        case "low": return .low
        case "high": return .high
        default: return .normal
        }
    }

    static func ok() -> Data {
        response(status: "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    static func badRequest(_ message: String = "Bad request") -> Data {
        response(status: "400 Bad Request", type: "text/plain", body: Data("\(message)\n".utf8))
    }

    static func notFound(_ message: String = "Not found") -> Data {
        response(status: "404 Not Found", type: "text/plain", body: Data("\(message)\n".utf8))
    }

    static func forbidden(_ message: String) -> Data {
        response(status: "403 Forbidden", type: "text/plain", body: Data("\(message)\n".utf8))
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        guard let body = try? JSONEncoder().encode(value) else {
            // Never downgrade to `null` + 200: that made an empty library look like a wiped one.
            GoelLog.remote.error("Remote API response could not be encoded")
            return response(status: "500 Internal Server Error", type: "text/plain",
                            body: Data("Could not encode the response\n".utf8))
        }
        return response(status: "200 OK", type: "application/json", body: body)
    }

    static func response(status: String, type: String, body: Data,
                         extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Emit only one Cache-Control: with both, caching is up to whichever header the client reads last.
        if extraHeaders["Cache-Control"] == nil {
            head += "Cache-Control: no-store\r\n"
        }
        // CSP: the portal renders download names, tracker hosts and errors that came from off-machine.
        head += "Content-Security-Policy: default-src 'none'; script-src 'self'; "
        head += "style-src 'self'; img-src 'self' data:; media-src 'self'; "
        head += "connect-src 'self'; form-action 'self'; base-uri 'none'\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private struct AddPayload: Decodable {
        var url: String
        var folder: String?
        var priority: String?
        var paused: Bool?
        var network: String?
    }

    private struct AggregationPayload: Decodable {
        var aggregation: Bool?
        var adapters: [String]?
        var streams: Int?

        private enum CodingKeys: String, CodingKey {
            case aggregation, adapters, streams, streamsPerAdapter
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aggregation = try c.decodeIfPresent(Bool.self, forKey: .aggregation)
            adapters = try c.decodeIfPresent([String].self, forKey: .adapters)
            // `GET` answers with `streamsPerAdapter`, so posting that object back must also work.
            streams = try c.decodeIfPresent(Int.self, forKey: .streams)
                ?? c.decodeIfPresent(Int.self, forKey: .streamsPerAdapter)
        }
    }
    private struct NewFolderPayload: Decodable {
        var name: String
        var parent: String?
    }
    private struct NewFolderRow: Encodable {
        var path: String
    }

    private struct CountRow: Encodable {
        var added: Int
        var refused: Int
    }
    private struct ConfigRow: Encodable {
        var username: String
        var readOnly: Bool
        var requireAuth: Bool
        var theme: String
        var appName = "Goel°"
    }

    struct TaskRow: Encodable {
        var id: String
        var name: String
        var status: String
        var statusToken: String
        var kind: String
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
            streamable = RemoteStreamService.streamPlan(for: task) != nil
        }
    }

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
        var adapterId: String?
        var adapterLabel: String?
        init(_ c: TaskConnection) {
            id = c.id
            label = c.label
            detail = c.detail
            down = c.downloadSpeed
            up = c.uploadSpeed
            progress = c.progress
            adapterId = c.adapterId
            adapterLabel = c.adapterLabel
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

    /// nil until the whole header block has arrived — a POST body can trail in a later segment.
    static func headerEnd(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data)
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i + 4 }
            i += 1
        }
        return nil
    }

    static func contentLength(_ header: Data) -> Int {
        for line in String(decoding: header, as: UTF8.self).split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

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
    /// The default implementation returns `true` — a conformer that forgets this allows every folder.
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool

    func networkState() async -> RemoteNetworkState
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async

    /// Reach is bounded by the server uid, not by a root of ours.
    func folderListing(_ path: String?) async -> RemoteFolderListing?
    func createFolder(named name: String, in parent: String?) async -> String?
}

public extension RemoteBackend {
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool { true }
    func folderListing(_ path: String?) async -> RemoteFolderListing? { nil }
    func createFolder(named name: String, in parent: String?) async -> String? { nil }
    func networkState() async -> RemoteNetworkState { RemoteNetworkState() }
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async {}
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async {
        await remoteAdd(source: source, saveDirectory: saveDirectory,
                        priority: priority, startPaused: startPaused)
    }
}

public struct RemoteFolderListing: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var name: String
        public var path: String
        public var readable: Bool
        public var writable: Bool

        public init(name: String, path: String, readable: Bool = true, writable: Bool = true) {
            self.name = name
            self.path = path
            self.readable = readable
            self.writable = writable
        }
    }

    public var path: String
    public var parent: String?
    public var folders: [Entry]
    public var writable: Bool
    public var home: String
    public var defaultFolder: String
    public var places: [Entry]

    public init(path: String, parent: String?, folders: [Entry], writable: Bool,
                home: String, defaultFolder: String, places: [Entry]) {
        self.path = path
        self.parent = parent
        self.folders = folders
        self.writable = writable
        self.home = home
        self.defaultFolder = defaultFolder
        self.places = places
    }
}

public struct RemoteNetworkState: Sendable, Codable, Equatable {
    public struct Adapter: Sendable, Codable, Equatable {
        public var name: String
        public var label: String
        public var type: String
        public var ipv4: String?
        public var expensive: Bool
        public var eligible: Bool

        public init(name: String, label: String, type: String, ipv4: String?,
                    expensive: Bool, eligible: Bool) {
            self.name = name
            self.label = label
            self.type = type
            self.ipv4 = ipv4
            self.expensive = expensive
            self.eligible = eligible
        }
    }

    public var aggregation: Bool
    public var streamsPerAdapter: Int
    public var selected: [String]
    public var reason: String?
    /// `/etc/goel/config` pins `GOEL_AGGREGATION` — a change made here lasts only until the next restart.
    public var locked: Bool
    public var adapters: [Adapter]

    public init(aggregation: Bool = false, streamsPerAdapter: Int = 2,
                selected: [String] = [], reason: String? = nil, locked: Bool = false,
                adapters: [Adapter] = []) {
        self.aggregation = aggregation
        self.streamsPerAdapter = streamsPerAdapter
        self.selected = selected
        self.reason = reason
        self.locked = locked
        self.adapters = adapters
    }
}

extension DownloadManager: RemoteBackend {
    public func taskSnapshot() async -> [DownloadTask] { snapshot }
    public func remoteAdd(source: DownloadSource) async { _ = add(source: source, saveDirectory: nil) }
    public func remoteAdd(source: DownloadSource, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async {
        _ = add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
                priority: priority, startPaused: startPaused)
    }

    public func remoteAdd(source: DownloadSource, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool,
                          network: NetworkSelection?) async {
        _ = add(source: source, saveDirectory: remoteSaveDirectory(saveDirectory),
                priority: priority, startPaused: startPaused, network: network)
    }

    public func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.canSave(into: folder)
        }.value
    }

    // These must hop off the actor: stat-ing a network-mounted folder would stall every download.
    public func folderListing(_ path: String?) async -> RemoteFolderListing? {
        let defaultFolder = settings.defaultSaveDirectory
        return await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.listing(
                of: path, defaultFolder: defaultFolder, home: NSHomeDirectory())
        }.value
    }

    public func createFolder(named name: String, in parent: String?) async -> String? {
        let defaultFolder = settings.defaultSaveDirectory
        return await Task.detached(priority: .userInitiated) {
            SaveFolderBrowser.create(named: name, in: parent, defaultFolder: defaultFolder)
        }.value
    }

    public func networkState() async -> RemoteNetworkState {
        let all = AdapterDirectory.enumerate()
        let bindable = Set(Self.bindableAdapters(
            settings: settings, vpnDefaultRoute: vpnDefaultRouteActive, all: all)
            .map(\.bsdName))
        return RemoteNetworkState(
            aggregation: settings.aggregationEnabled,
            streamsPerAdapter: settings.aggregationStreamsPerAdapter,
            selected: settings.aggregationAdapterIds,
            reason: Self.aggregationSinglePathReason(
                settings: settings, vpnDefaultRoute: vpnDefaultRouteActive, adapters: all)?.rawValue,
            locked: ProcessInfo.processInfo.environment["GOEL_AGGREGATION"] != nil,
            adapters: all.map {
                RemoteNetworkState.Adapter(
                    name: $0.bsdName, label: $0.shortLabel, type: $0.type, ipv4: $0.ipv4,
                    expensive: $0.isExpensive, eligible: bindable.contains($0.bsdName))
            })
    }

    public func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async {
        var updated = settings
        if let enabled { updated.aggregationEnabled = enabled }
        if let adapterIds {
            updated.aggregationAdapterIds = adapterIds.filter(NetworkSelection.isValidInterfaceName)
        }
        if let streams { updated.aggregationStreamsPerAdapter = min(8, max(1, streams)) }
        await updateSettings(updated)
    }

    /// The check is the filesystem's, not a root of ours — a real widening of what a remote add may write.
    func remoteSaveDirectory(_ folder: String?) -> String? {
        guard let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        if SaveFolderBrowser.canSave(into: folder) { return folder }
        GoelLog.remote.error("Remote add: save folder is not writable; using default",
                             .path(folder))
        return nil
    }
}
