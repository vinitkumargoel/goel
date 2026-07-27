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

        // Cross-site write protection. The session cookie is SameSite=Strict, so a
        // third-party page cannot ride an existing sign-in — but an *open* portal
        // (`requireAuth == false`) authorises everyone, and a page in the user's
        // browser can POST to 127.0.0.1 with a simple content type and no preflight.
        // Browsers attach `Origin` to every POST, so a present-but-foreign Origin is
        // a cross-site write: refuse it. Absent means a non-browser client (curl,
        // the extension), which was never the threat. This does not defend against
        // DNS rebinding — the rebound page's Origin matches Host — and a Host
        // allowlist that would is incompatible with the documented reverse-proxy
        // deployment, where Host is a real hostname.
        guard Self.crossSiteWriteAllowed(request) else {
            return Self.forbidden("Cross-site request refused.")
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

        // Also reachable ahead of the auth gate (see `staticAsset`); handled here
        // too so the router is complete on its own and testable in isolation.
        case ("GET", let path) where path.hasPrefix(Self.assetPrefix):
            return Self.staticAsset(path: path) ?? Self.notFound()

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
            // Refuse a folder we cannot write instead of quietly saving somewhere
            // else: a remote client that is told "added" has a right to assume the
            // file landed where it asked.
            // ``DownloadManager/remoteSaveDirectory(_:)`` stays in place as the
            // belt-and-braces check.
            if let folder, !folder.isEmpty, await backend.remoteSaveDirectoryAllowed(folder) == false {
                return Self.forbidden("That save folder cannot be written to — it does not exist, is not a folder, or this user has no permission for it.")
            }
            let priority = Self.priority(payload.priority)
            let paused = payload.paused ?? false
            // Refuse a malformed spec rather than silently downgrading to `auto`:
            // "I picked one interface and it used both" is the wrong surprise.
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
            // The portal is a network-facing surface: a caller-supplied URL must not
            // be able to steer this host at its own loopback or at the cloud-metadata
            // range. A magnet names no fetchable host here — its swarm is reached by
            // infohash — so only the URL-bearing sources are screened.
            // Screened by resolved address, not just by spelling: a hostname that
            // resolves to 127.0.0.1 (`localtest.me`) or to the metadata range
            // (`metadata.google.internal`) is the same request with the digits
            // hidden behind DNS.
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

        // MARK: Save-folder picker
        //
        // Exists so the portal never asks anyone to type an absolute server path.
        // A typed path is both tedious and easy to get wrong, and a wrong one is
        // refused by `/api/add` only *after* the user has composed the whole
        // request. Browsing makes the unsafe value unreachable instead.
        //
        // This *is* a filesystem browser for the machine, bounded by the server
        // process's own uid rather than by a configured root — see
        // ``SaveFolderBrowser`` for why, and for what it costs. `path` omitted
        // means the configured downloads folder, which is where it opens.
        case ("GET", "/api/folders"):
            guard let listing = await backend.folderListing(request.query["path"]) else {
                return Self.notFound("That folder does not exist, or is not a folder.")
            }
            return Self.json(listing)

        case ("POST", "/api/folder"):
            guard let payload = try? JSONDecoder().decode(NewFolderPayload.self, from: request.body)
            else { return Self.badRequest() }
            // Reject rather than silently sanitise. `PathSafety.sanitizedName`
            // falls back to "download" for a hostile name, which would create a
            // folder the user did not ask for and did not name — a confusing
            // outcome for what is plainly a bad request.
            let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isPlainFolderName(name) else {
                return Self.badRequest("A folder name cannot be empty, contain “/”, or begin with a dot.")
            }
            guard let created = await backend.createFolder(named: name, in: payload.parent) else {
                return Self.forbidden(
                    "Could not create that folder — this user may not have permission to write there.")
            }
            return Self.json(NewFolderRow(path: created))

        // MARK: Network
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
            // Echo the resulting state so the UI shows what the server decided —
            // including a reason the change did not switch aggregation on.
            return Self.json(await backend.networkState())

        // MARK: History mutations
        case ("POST", "/api/history-remove"):
            guard let id = queryID(request) else { return Self.badRequest() }
            await backend.removeHistoryEntry(id); return Self.ok()

        default:
            return Self.response(status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    static let assetPrefix = "/assets/"

    /// The compiled UI, served ahead of the auth gate.
    ///
    /// Returns nil when `path` is not an asset path at all, so callers can fall
    /// through; an asset path naming something unknown yields a 404 rather than
    /// nil, because there is nothing else it could have meant.
    ///
    /// **Serving these unauthenticated is deliberate.** The login page needs its
    /// own stylesheet and script before anyone has signed in, and gating them
    /// would render it unstyled and inert. Nothing here is a secret: the bundle
    /// is byte-identical for every user and every deployment, and carries no
    /// configuration — the per-session `BOOT` object lives in the page shell,
    /// which stays behind the gate.
    ///
    /// Lookup is a dictionary hit on the filename and never touches a
    /// filesystem, so there is no path traversal to defend against:
    /// `/assets/../../etc/passwd` is simply not a key.
    ///
    /// Filenames carry a content hash, which is what makes the immutable
    /// year-long cache safe — new bytes mean a new URL, so a cached copy can
    /// never be served against a newer shell.
    static func staticAsset(path: String) -> Data? {
        guard path.hasPrefix(assetPrefix) else { return nil }
        let name = String(path.dropFirst(assetPrefix.count))
        guard let asset = PortalBundle.assets[name] else { return notFound() }
        return response(status: "200 OK", type: asset.mime, body: Data(asset.body.utf8),
                        extraHeaders: ["Cache-Control": "public, max-age=31536000, immutable"])
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

    /// Whether a POST may proceed given the `Origin` its browser attached. No
    /// `Origin` means no browser, which is the scripted/extension path and always
    /// allowed; a foreign one is a cross-site write.
    ///
    /// `X-Forwarded-Host` counts as an authority too, because a reverse proxy that
    /// does not rewrite `Host` leaves it naming the *upstream* (`127.0.0.1:8899`)
    /// while the browser's Origin names the public hostname — a legitimate request
    /// that a bare Host comparison would refuse. It cannot be abused to bypass the
    /// check: a cross-site page can only add that header through a request that
    /// takes a CORS preflight, and the portal answers no preflight.
    static func crossSiteWriteAllowed(_ request: RemoteRequest) -> Bool {
        guard request.method == "POST", let origin = request.headers["origin"] else { return true }
        return originMatchesHost(origin, host: request.headers["host"])
            || originMatchesHost(origin, host: request.headers["x-forwarded-host"])
    }

    /// Whether `origin` names the same authority the request was addressed to.
    /// Scheme is ignored: the `Host` header carries none, and the socket only ever
    /// speaks one scheme.
    static func originMatchesHost(_ origin: String, host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty,
              let url = URL(string: origin.trimmingCharacters(in: .whitespaces)),
              let originHost = url.host?.lowercased() else { return false }
        if let port = url.port { return "\(originHost):\(port)" == host }
        return originHost == host
    }

    /// One SSE frame (`data: <json>\n\n`) for the live event stream, or nil when
    /// the snapshot could not be encoded — see ``json(_:)`` for why that is not
    /// downgraded into an empty list.
    public func eventFrame(for tasks: [DownloadTask]) -> Data? {
        let rows = tasks.map(TaskRow.init)
        guard let json = try? JSONEncoder().encode(rows) else { return nil }
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

    /// A single path component that names a folder and nothing else.
    ///
    /// Deliberately stricter than ``PathSafety/sanitizedName(_:fallback:)``: that
    /// one repairs a bad name, which is right when a server hands us a filename
    /// but wrong for a name a person typed — silently creating "download" because
    /// they typed "../" is worse than saying no.
    static func isPlainFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 240 else { return false }
        guard !trimmed.hasPrefix(".") else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        // Control characters and NUL would produce a path the user cannot read
        // back or re-select in the picker.
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

    // MARK: Response building

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
            // Encoding can only fail on a non-finite Double reaching a wire model
            // from one of the engine bridges. `null` with a 200 told the client
            // "here is your data, there is none" — an empty library is then
            // indistinguishable from a wiped one. Say it failed instead.
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
        // `no-store` is the right default for every dynamic response here, but
        // the hashed bundle assets must override it — emitting both would leave
        // the caching behaviour up to whichever header the client reads last.
        if extraHeaders["Cache-Control"] == nil {
            head += "Cache-Control: no-store\r\n"
        }
        // Defense-in-depth for the control page. Script and style come from
        // /assets/ under content-addressed names, so 'self' is enough and inline
        // execution can be refused outright — which matters because the portal
        // renders download names, tracker hosts and error strings that originate
        // off-machine. Also allowed: same-origin fetch/SSE, streamed media, and
        // the inline SVG/data: favicon. Forms post same-origin; nothing may
        // frame us.
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

    // MARK: Wire models

    private struct AddPayload: Decodable {
        var url: String
        var folder: String?
        var priority: String?
        var paused: Bool?
        /// A ``NetworkSelection`` spec ("auto", "single:eth0", "aggregate:a,b").
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
            // `GET` answers with `streamsPerAdapter`, so posting that object back
            // must work — accepting only `streams` made the field vanish silently,
            // out-of-range value and all.
            streams = try c.decodeIfPresent(Int.self, forKey: .streams)
                ?? c.decodeIfPresent(Int.self, forKey: .streamsPerAdapter)
        }
    }
    private struct NewFolderPayload: Decodable {
        var name: String
        /// Absolute path of the folder to create it in. Omitted means the
        /// downloads root; the backend re-checks containment either way.
        var parent: String?
    }
    private struct NewFolderRow: Encodable {
        var path: String
    }

    private struct CountRow: Encodable {
        var added: Int
        /// Sources dropped by the internal-address guard, so the portal can say so
        /// rather than reporting a partial batch as a clean success.
        var refused: Int
    }
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
            streamable = RemoteStreamService.streamPlan(for: task) != nil
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

    /// Index just past the `\r\n\r\n` that terminates the header block, or nil if
    /// the headers haven't fully arrived yet. Lets a socket layer know it has read
    /// enough to begin parsing — and where the body starts — so it can keep reading
    /// until a *complete* request is in hand (a POST body can trail the headers in
    /// a later TCP segment). Shared by both the macOS and Linux server shells.
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

    /// The `Content-Length` declared in a header block (0 if absent/malformed).
    static func contentLength(_ header: Data) -> Int {
        for line in String(decoding: header, as: UTF8.self).split(separator: "\r\n") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
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
    /// Whether a caller-supplied save folder can actually receive a download: it
    /// exists, it is a directory, and this uid may write to it. Defaulted to
    /// `true` so in-memory conformers keep compiling; the real scheduler answers
    /// with ``SaveFolderBrowser/canSave(into:)``.
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool

    /// Live interfaces plus the current aggregation policy, for `GET /api/network`.
    func networkState() async -> RemoteNetworkState
    /// Apply an aggregation change from the portal. nil = leave that field alone.
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async
    /// Add with a per-download interface choice.
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async

    /// Subfolders of `path`, for the portal's save-folder picker. nil `path` means
    /// the configured downloads folder, which is where the picker opens. Returns
    /// nil only when the path does not exist or is not a directory — reach is
    /// bounded by the server process's uid, not by a configured root.
    func folderListing(_ path: String?) async -> RemoteFolderListing?
    /// Create `name` inside `parent` (nil = the configured downloads folder) and
    /// answer with the new absolute path. nil when the create failed, which
    /// includes having no permission to write there.
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

/// One level of the save-folder tree, as the portal's picker needs it.
///
/// Absolute paths travel on the wire because that is what `POST /api/add` takes,
/// and because the alternative — a relative path the server re-joins — would need
/// its own traversal check on the way back in. `parent` and `places` let the
/// picker render an "up" affordance and its shortcuts without doing path
/// arithmetic in JavaScript.
///
/// There is no root field. The picker reaches wherever the server process's uid
/// reaches; `readable`/`writable` per entry are what the UI greys out, and they
/// are the kernel's answers rather than a policy of ours. See
/// ``SaveFolderBrowser`` for what that widening costs.
public struct RemoteFolderListing: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var name: String
        public var path: String
        /// False when this uid may not list the folder — the picker shows it but
        /// will not enter it, rather than offering a click that dead-ends.
        public var readable: Bool
        /// False when this uid may not write into it, so it cannot be chosen as a
        /// destination.
        public var writable: Bool

        public init(name: String, path: String, readable: Bool = true, writable: Bool = true) {
            self.name = name
            self.path = path
            self.readable = readable
            self.writable = writable
        }
    }

    /// The folder being listed.
    public var path: String
    /// The folder above `path`, or nil at `/`.
    public var parent: String?
    /// Immediate subfolders, name-sorted. Files are not listed: this picker only
    /// ever answers "where should this go".
    public var folders: [Entry]
    /// False when the folder cannot be written to, so the picker can refuse to
    /// offer "New folder" rather than surfacing an error after the fact.
    public var writable: Bool
    /// The server user's home directory, so the picker can label paths under it
    /// as `~/…` instead of showing the full absolute path.
    public var home: String
    /// The configured default save directory. Choosing exactly this means "use
    /// the default", which the portal sends as a blank `folder`.
    public var defaultFolder: String
    /// One-click destinations: Downloads, Home, mounted volumes, Computer.
    /// Shortcuts only — all of them are reachable by walking up as well.
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

/// What the portal needs to render the network section: every interface it may
/// bind to, which ones the current policy uses, and why it is not splitting.
public struct RemoteNetworkState: Sendable, Codable, Equatable {
    public struct Adapter: Sendable, Codable, Equatable {
        public var name: String
        public var label: String
        public var type: String
        public var ipv4: String?
        public var expensive: Bool
        /// False when the interface exists but cannot be bound right now (a proxy
        /// or VPN policy is in force), so the UI can grey it out instead of
        /// offering a choice that would be silently ignored.
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
    /// Why aggregation is not currently running, nil when it is.
    public var reason: String?
    /// True when `/etc/goel/config` pins `GOEL_AGGREGATION`, so a change made here
    /// lasts only until the next restart. The portal says so rather than lying.
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

    // All three hop off the actor to touch the filesystem. Listing a folder stats
    // every entry in it, and a folder can be large and can live on a network mount
    // — long enough to stall every download in the scheduler while a browser walks
    // a directory tree. Only the settings reads happen under isolation.
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
            // The daemon's own environment is the authority — no plumbing needed, and
            // it is empty on macOS, where the setting is never env-pinned.
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

    /// Accept a remote-supplied save directory if this uid can actually write to
    /// it, and fall back to the per-source default otherwise (→ nil).
    ///
    /// The check is the filesystem's, not a root of ours: a portal session may
    /// save anywhere the server process may. That is a real widening of a
    /// network-facing surface — on macOS the app runs as the logged-in user, so
    /// `~/Library/LaunchAgents` is now a writable destination like any other, and
    /// the portal password is the whole of what guards it. It is deliberate;
    /// ``SaveFolderBrowser`` records the reasoning.
    func remoteSaveDirectory(_ folder: String?) -> String? {
        guard let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        if SaveFolderBrowser.canSave(into: folder) { return folder }
        GoelLog.remote.error("Remote add: save folder is not writable; using default",
                             .path(folder))
        return nil
    }
}
