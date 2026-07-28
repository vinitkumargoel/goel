import Foundation

actor HTTPEngine: HTTPConfigurable {

    public nonisolated let kind: DownloadKind = .http

    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .producesResumeData] }

    private nonisolated let hub = EventHub()

    var session: URLSession

    var profile: TrafficProfile

    var networkConfig = HTTPEngine.defaultNetworkConfig

    var aggregationConfig = AggregationEngineConfig.disabled

    /// Must read the same picker as ``DownloadManager/makeTask``, or "Overwrite" still makes `name (1).mp4`.
    var fileConflictPolicy = "rename"

    var connectionBudget = ConnectionBudget()

    let downloadPacer: RateLimiter

    var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    private var streamedResume: [UUID: Data] = [:]

    static let flushSize = 64 * 1024

    /// `URLSession` defaults to **6** on macOS — below High's 16-way fan-out, so extra connections silently queue.
    static let maxConnectionsPerHost = 16

    /// Rejects an absurd server `Content-Length` that would trigger a huge preallocation.
    static let maxDownloadSize: Int64 = 100 * 1024 * 1024 * 1024

    /// Foundation sends no UA for data/bytes tasks and some WAFs silently reset those as -1005.
    static let userAgent = "GoelDownloader/1.0 (macOS)"

    /// Servers 429 excess *concurrent* range connections (~3, Hetzner); backoff lets a segment recover.
    static let maxRequestAttempts = 10

    static let defaultNetworkConfig = HTTPNetworkConfig(
        timeout: 60,
        retryCount: maxRequestAttempts,
        retryInterval: 0,
        userAgent: userAgent,
        proxyMode: "system",
        proxyHost: "",
        proxyPort: 0,
        cookieAuthEnabled: true
    )

    nonisolated let credentials: any CredentialProviding

    public init(session: URLSession, profile: TrafficProfile = .high,
                credentials: any CredentialProviding = KeychainCredentialStore()) {
        self.session = session
        self.profile = profile
        self.credentials = credentials
        self.downloadPacer = RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
    }

    init(configuration: URLSessionConfiguration, profile: TrafficProfile = .high,
                credentials: any CredentialProviding = KeychainCredentialStore()) {
        configuration.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost
        self.session = URLSession(configuration: configuration,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
        self.profile = profile
        self.credentials = credentials
        self.downloadPacer = RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
    }

    init(profile: TrafficProfile = .high,
                credentials: any CredentialProviding = KeychainCredentialStore()) {
        let config = URLSessionConfiguration.default
        #if !os(Linux)
        // `waitsForConnectivity` is get-only in swift-corelibs-foundation.
        config.waitsForConnectivity = true
        #endif
        config.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost
        self.session = URLSession(configuration: config,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
        self.profile = profile
        self.credentials = credentials
        self.downloadPacer = RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
    }

    func add(_ task: DownloadTask) async {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        let id = task.id
        jobs[id] = Task { await self.run(id) }
    }

    func pause(_ id: DownloadTask.ID) async {
        guard let job = jobs[id] else { return }
        job.cancel()
        jobs[id] = nil
        // The cursor is ~1s stale, which is safe: resume re-validates ETag / Last-Modified before reusing a range.
        if let data = streamedResume[id] {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
        tasks[id]?.status = .paused
        tasks[id]?.downloadSpeed = 0
        tasks[id]?.connectionCount = 0
        // Do NOT echo .statusChanged(.paused): a stale echo arriving after a later resume re-pauses the task.
    }

    func resume(_ id: DownloadTask.ID) async {
        guard tasks[id] != nil, jobs[id] == nil else { return }
        emit(id, .statusChanged(.downloading))
        jobs[id] = Task { await self.run(id) }
    }

    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        let job = jobs[id]
        let task = tasks[id]
        job?.cancel()
        jobs[id] = nil
        // Clear the map BEFORE the suspension below, or a concurrent resume() slots a fresh job into a dying task.
        tasks[id] = nil
        // Wait for the unwind before deleting, so a segment writer can't flush bytes to a path we just unlinked.
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
        streamedResume[id] = nil
    }

    func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
        await downloadPacer.setRate(profile.maxDownloadBytesPerSec)
    }

    /// A `URLSessionConfiguration` freezes once used, so the config is copied, mutated and swapped in.
    func applyNetworkConfig(_ config: HTTPNetworkConfig) async {
        self.networkConfig = config

        let cfg = session.configuration
        // Never set `timeoutIntervalForResource`: it caps the whole transfer and kills long downloads.
        cfg.timeoutIntervalForRequest = config.timeout
        // Re-apply across config swaps or a fresh configuration reverts to Foundation's default of 6.
        cfg.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost

        var headers = cfg.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = config.userAgent
        cfg.httpAdditionalHeaders = headers

        cfg.httpShouldSetCookies = config.cookieAuthEnabled
        cfg.httpCookieAcceptPolicy = config.cookieAuthEnabled ? .always : .never
        cfg.httpCookieStorage = config.cookieAuthEnabled ? HTTPCookieStorage.shared : nil

        #if os(Linux)
        // CFNetwork proxy-dictionary keys don't exist in swift-corelibs-foundation; use http(s)_proxy env vars.
        switch config.proxyMode {
        case "manual" where !config.proxyHost.isEmpty && config.proxyPort > 0:
            let proxy = "http://\(config.proxyHost):\(config.proxyPort)"
            setenv("http_proxy", proxy, 1)
            setenv("https_proxy", proxy, 1)
        default:
            // Must clear an earlier manual proxy, or manual→system keeps routing every download through it.
            unsetenv("http_proxy"); unsetenv("https_proxy")
        }
        #else
        switch config.proxyMode {
        case "manual" where !config.proxyHost.isEmpty && config.proxyPort > 0:
            if config.proxyType == "socks5" {
                cfg.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: 1,
                    kCFNetworkProxiesSOCKSProxy as String: config.proxyHost,
                    kCFNetworkProxiesSOCKSPort as String: config.proxyPort,
                ]
            } else {
                cfg.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPProxy as String: config.proxyHost,
                    kCFNetworkProxiesHTTPPort as String: config.proxyPort,
                    kCFNetworkProxiesHTTPSEnable as String: 1,
                    kCFNetworkProxiesHTTPSProxy as String: config.proxyHost,
                    kCFNetworkProxiesHTTPSPort as String: config.proxyPort,
                ]
            }
        case "none":
            cfg.connectionProxyDictionary = [:]   // explicitly bypass any proxy
        default:
            cfg.connectionProxyDictionary = nil   // "system": follow OS proxy settings
        }
        #endif

        // Park, don't deallocate: freeing a corelibs `URLSession` can abort the process.
        SessionPool.retire(session)

        // Re-attach the sanitizer: a config copy drops the delegate, silently ending cross-host header stripping.
        self.session = URLSession(configuration: cfg,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
    }

    func configure(_ net: HTTPNetworkConfig) async {
        await applyNetworkConfig(net)
    }

    func configureAggregation(_ config: AggregationEngineConfig) async {
        aggregationConfig = config
    }

    func configureFileConflictPolicy(_ policy: String) async {
        fileConflictPolicy = policy
    }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source else { return nil }
        let last = url.lastPathComponent
        let base = (last.isEmpty || last == "/") ? (url.host ?? "download") : last
        let currentName = PathSafety.sanitizedName(base, fallback: url.host ?? "download")
        let r = await resolveMetadata(for: url, currentName: currentName)
        return EngineMetadata(name: r.name, totalBytes: r.totalBytes, reachable: r.reachable,
                              suggestedChecksum: r.checksum)
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        guard var task = tasks[id] else { return }
        if let idx = task.files.firstIndex(where: { $0.id == fileID }) {
            task.files[idx].priority = priority
            tasks[id] = task
        }
    }

    nonisolated func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }

    private func run(_ id: UUID) async {
        guard let task = tasks[id], case .url(let url) = task.source else {
            let e = DownloadError.unknown("HTTPEngine requires a URL source")
            tasks[id]?.status = .failed(e)
            hub.fail(id, e)
            return
        }

        // Defense-in-depth: never write outside the save directory if a hostile name slipped past sanitisation.
        guard task.isSavePathContained else {
            let e = DownloadError.unknown("Path traversal blocked")
            tasks[id]?.status = .failed(e)
            jobs[id] = nil
            hub.fail(id, e)
            return
        }

        tasks[id]?.status = .downloading
        emit(id, .statusChanged(.downloading))

        do {
            try ensureDirectory(task.saveDirectory)
            let probe = try await probe(url, referer: task.referer,
                                        extraHeaders: task.outboundHeaders(for: url))

            if let total = probe.totalBytes {
                // Only the tail needs fresh space: preflighting the full `total` wrongly rejects a resumed download.
                let alreadyOnDisk = Self.resumedBytesOnDisk(task.resumeData, total: total)
                try checkDiskSpace(task.saveDirectory, needed: max(0, total - alreadyOnDisk))
            }

            emit(id, .remoteInfoResolved(RemoteInfo(
                server: probe.server,
                etag: probe.etag,
                acceptRanges: probe.acceptsRanges,
                mimeType: probe.contentType
            )))

            // Rename ONLY on a run that wrote nothing: on resume `uniqueName` steps over the partial and restarts.
            let isFirstAttempt = task.resumeData == nil && task.bytesDownloaded == 0
            if isFirstAttempt,
               let better = Self.refinedName(current: task.name,
                                             suggestedName: probe.suggestedName,
                                             contentType: probe.contentType) {
                let unique = DownloadManager.resolveName(better, in: task.saveDirectory,
                                                         policy: fileConflictPolicy)
                if unique != task.name {
                    tasks[id]?.name = unique
                    emit(id, .nameResolved(unique))
                }
            }

            // Re-read the possibly-renamed task and re-assert path containment.
            guard let resolved = tasks[id], resolved.isSavePathContained else {
                let e = DownloadError.unknown("Path traversal blocked")
                tasks[id]?.status = .failed(e)
                jobs[id] = nil
                hub.fail(id, e)
                return
            }
            let fileURL = URL(fileURLWithPath: resolved.savePath)

            if let total = probe.totalBytes {
                tasks[id]?.totalBytes = total
                emit(id, .metadataResolved(
                    name: resolved.name,
                    totalBytes: total,
                    files: [TransferFile(id: 0, path: resolved.name, length: total)]
                ))
            }

            // Basic auth only ever rides over TLS — it would be cleartext otherwise.
            let authorization = url.scheme?.lowercased() == "https"
                ? url.host.flatMap { credentials.basicAuthorization(forHost: $0) }
                : nil
            let settings = RequestSettings(
                userAgent: networkConfig.userAgent,
                maxAttempts: networkConfig.retryCount,
                retryInterval: networkConfig.retryInterval,
                authorization: authorization,
                referer: resolved.referer,
                extraHeaders: resolved.outboundHeaders(for: url)
            )

            let host = url.host
            let canSegment = probe.totalBytes != nil && probe.acceptsRanges
            var segmentCount = canSegment ? resolveSegmentCount(total: probe.totalBytes!, host: host) : 1

            let resolution = AggregationPolicy.bindTargets(
                for: resolved.networkSelection,
                defaultAdapters: aggregationConfig.isActive ? aggregationConfig.adapters : [],
                available: aggregationConfig.available)
            if let note = resolution.note {
                GoelLog.engineHTTP.notice("Network selection adjusted", .detail(note))
            }
            let boundAdapters = resolution.adapters
            if boundAdapters.count >= 2, !canSegment {
                let willReprobe = SegmentedTransfer.shouldAttemptUpgrade(
                    totalBytes: probe.totalBytes, acceptsRanges: probe.acceptsRanges,
                    etag: probe.etag, lastModified: probe.lastModified)
                GoelLog.engineHTTP.notice("Aggregation unavailable: server does not support ranged requests",
                    .host(host ?? "unknown"),
                    .count(boundAdapters.count, label: "adapters"),
                    .flag(willReprobe, label: "willReprobeMidDownload"))
            }
            if canSegment, boundAdapters.count >= 2 {
                let hostRoom = connectionBudget.hostRoom(
                    host: host, maxPerServer: profile.maxConnectionsPerServer)
                let globalRoom = connectionBudget.globalRoom(
                    maxConnections: profile.maxConnections)
                segmentCount = AggregationPolicy.multiPathSegmentCount(
                    fileBytes: probe.totalBytes!,
                    adapters: boundAdapters.count,
                    streamsPerAdapter: aggregationConfig.streamsPerAdapter,
                    maxConnectionsPerServer: hostRoom,
                    globalRoom: globalRoom)
            }

            // Only the task's OWN limit rides on the plan; folding in the profile ceiling let N downloads hit N×.
            let maxBytesPerSecond = resolved.speedLimitBytesPerSec ?? 0

            // The manager already sanitized these mirrors to http/https, deduped and capped them.
            let mirrors = (resolved.mirrors ?? []).compactMap(URL.init(string:))

            var plan = TransferPlan(
                url: url,
                destination: fileURL,
                totalBytes: probe.totalBytes,
                acceptsRanges: probe.acceptsRanges,
                etag: probe.etag,
                lastModified: probe.lastModified,
                existingResume: resolved.resumeData,
                segmentCount: segmentCount,
                session: session,
                settings: settings,
                maxBytesPerSecond: maxBytesPerSecond,
                sharedLimiter: downloadPacer,
                flushSize: Self.flushSize,
                mirrors: mirrors,
                boundAdapters: boundAdapters,
                connectTimeout: networkConfig.timeout
            )
            let extraGrants = ExtraGrantCounter()
            plan.requestExtraConnections = { [weak self] wanted in
                guard let self, wanted > 0 else { return 0 }
                let granted = await self.grantExtraConnections(host: host, wanted: wanted)
                extraGrants.add(granted)
                return granted
            }
            let planned = PlannedTransfer(plan: plan)

            // Charge the count the transfer will ACTUALLY open — resume may restore a different one.
            let reserved = planned.connectionCount
            reserveConnections(host: host, count: reserved)
            // Balance to zero on EVERY exit: the initial reservation plus every mid-flight grant.
            defer { releaseConnections(host: host, count: reserved + extraGrants.total) }

            let progressStream = planned.progress
            let consumer = Task { [weak self] in
                for await update in progressStream { await self?.applyProgress(id, update) }
            }

            let outcome: TransferOutcome
            do {
                outcome = try await planned.run()
                await consumer.value
            } catch {
                consumer.cancel()
                await consumer.value
                throw error
            }

            try Task.checkCancellation()

            if let expected = task.expectedChecksum {
                tasks[id]?.downloadSpeed = 0
                tasks[id]?.status = .verifying
                emit(id, .statusChanged(.verifying))
                let matched = try await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)
                guard matched else { throw DownloadError.checksumMismatch }
            }

            // Streamed ticks are throttled, so force a final 100% emit here or the UI stops short.
            tasks[id]?.bytesDownloaded = outcome.bytesWritten
            tasks[id]?.connectionCount = 0
            tasks[id]?.downloadSpeed = 0
            emit(id, .progress(bytesDownloaded: outcome.bytesWritten, bytesUploaded: 0,
                               downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))
            emit(id, .fileProgress(fileID: 0, bytesCompleted: outcome.bytesWritten))
            tasks[id]?.status = .completed
            tasks[id]?.completedAt = Date()
            jobs[id] = nil
            hub.complete(id)
        } catch is CancellationError {
            // Our own pause()/remove() cancelled the job; they publish the state.
        } catch {
            // An EXTERNAL URLSession cancel (VPN reset, OS preemption) must not be swallowed: it strands the task.
            if Task.isCancelled { return }
            let de: DownloadError
            if let ue = error as? URLError, ue.code == .cancelled {
                de = .network("Connection reset")
            } else {
                de = DownloadError(mapping: error)
            }
            tasks[id]?.status = .failed(de)
            tasks[id]?.downloadSpeed = 0
            jobs[id] = nil
            hub.fail(id, de)
        }
    }

    static func resumedBytesOnDisk(_ resumeData: Data?, total: Int64) -> Int64 {
        guard let data = resumeData,
              let cursor = try? JSONDecoder().decode(SegmentedTransfer.ResumeCursor.self, from: data),
              cursor.totalBytes == total else { return 0 }
        // A cursor can arrive verbatim from an imported backup, and `reduce(0, +)` traps on `Int64` overflow.
        var done: Int64 = 0
        for segment in cursor.completed {
            guard segment >= 0 else { return 0 }
            let (sum, overflowed) = done.addingReportingOverflow(segment)
            if overflowed { return 0 }
            done = sum
        }
        return min(done, max(0, total))
    }

    private func applyProgress(_ id: UUID, _ update: TransferProgress) {
        guard tasks[id] != nil else { return }
        tasks[id]?.bytesDownloaded = update.bytesDownloaded
        tasks[id]?.downloadSpeed = update.downloadSpeed
        tasks[id]?.connectionCount = update.connectionCount
        emit(id, .progress(
            bytesDownloaded: update.bytesDownloaded,
            bytesUploaded: 0,
            downloadSpeed: update.downloadSpeed,
            uploadSpeed: 0,
            connectionCount: update.connectionCount
        ))
        emit(id, .fileProgress(fileID: 0, bytesCompleted: update.bytesDownloaded))
        if let data = update.resumeData {
            tasks[id]?.resumeData = data
            streamedResume[id] = data
            emit(id, .resumeDataUpdated(data))
        }
        if let connections = update.connections {
            emit(id, .connectionsUpdated(connections))
        }
    }

    nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }
}
