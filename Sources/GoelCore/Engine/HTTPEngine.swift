import Foundation

/// The production HTTP download engine.
///
/// Backs every `.url` source. It performs **segmented** (multi-connection)
/// downloads by issuing parallel HTTP `Range` requests, writing each segment to
/// its own offset in a preallocated file, and emitting aggregate progress. When
/// the server cannot satisfy ranges — or omits a `Content-Length` — it falls
/// back to a single streaming connection. It detects range support, validates
/// resume cursors against `ETag`/`Last-Modified`, checks free disk space before
/// writing, and tears down `URLSession` work cleanly on pause/remove.
///
/// The engine is an `actor`, so all of its mutable bookkeeping is serialized and
/// it is `Sendable` for free. The synchronous `kind` requirement is satisfied by
/// a `nonisolated let`.
actor HTTPEngine: HTTPConfigurable {

    // MARK: Identity

    public nonisolated let kind: DownloadKind = .http

    /// The HTTP engine probes servers for the add-confirmation preview and emits
    /// resume data, but has no per-file priority (a URL download is one file).
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata, .producesResumeData] }

    /// Lock-based fan-out of events to subscribers. Lives outside the actor's
    /// isolation so the synchronous `events(for:)` requirement can be satisfied
    /// by a `nonisolated` method.
    private nonisolated let hub = EventHub()

    // MARK: Dependencies

    // The engine's download state is `internal` (not `private`) so the actor's
    // sibling-file extensions (`+Probe` / `+Transfer` / `+Resume` / `+Disk`) can
    // reach it. Swift's `private` is file-scoped, so a split actor has no narrower
    // option; nothing here is exposed beyond the GoelCore module.

    /// `var` (not `let`) because `applyNetworkConfig` swaps in a freshly built
    /// session: a `URLSessionConfiguration` is immutable once a session exists,
    /// so timeout / proxy / cookie / User-Agent changes require a new session.
    var session: URLSession

    /// The active traffic profile. Drives the per-server segment count and the
    /// download bandwidth cap.
    var profile: TrafficProfile

    /// Network-layer configuration (timeout / proxy / User-Agent / cookies and
    /// the retry budget). Applied to the `URLSession` and consumed by the retry
    /// path. Defaults preserve the engine's built-in behaviour until the manager
    /// pushes a config derived from the user's Network settings.
    var networkConfig = HTTPEngine.defaultNetworkConfig

    /// Multi-path aggregation snapshot pushed from ``DownloadManager``. Default
    /// inactive so tests and single-path downloads stay on URLSession.
    var aggregationConfig = AggregationEngineConfig.disabled

    /// The user's "when a file exists" choice, pushed from ``DownloadManager``.
    /// The post-probe rename below re-resolves the on-disk name, so it must honour
    /// the same picker ``DownloadManager/makeTask`` reads — otherwise "Overwrite"
    /// still produced `name (1).mp4` whenever a `Content-Disposition` name
    /// collided. Defaults to the settings default so an unconfigured engine keeps
    /// the safe, non-clobbering behaviour.
    var fileConflictPolicy = "rename"

    /// Aggregate open-connection accounting across ALL concurrent downloads, so
    /// the profile's global `maxConnections` and per-host `maxConnectionsPerServer`
    /// caps hold in sum — not merely within a single task. Reserved when a
    /// download's segments start and released when it finishes / pauses / fails.
    /// Distinct from the per-download ``ConnectionGovernor`` (adaptive 429 shrink).
    var connectionBudget = ConnectionBudget()

    /// The engine-wide download pacer, threaded into every transfer's
    /// ``TransferPlan/sharedLimiter`` so the profile's byte cap holds in SUM across
    /// concurrent downloads — the whole-app "Max download speed" the Traffic pane
    /// presents — instead of each download claiming the full cap for itself. A
    /// per-task limit is chained in FRONT of this one (see
    /// ``SegmentedTransfer/makeLimiter``), so it stays private to its task.
    /// Retargeted in place by ``applyLimits(_:)``: it outlives any one download.
    let downloadPacer: RateLimiter

    // MARK: Per-task state

    var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    /// The most recent resume cursor STREAMED out of each download's transfer.
    /// `pause()` persists this (rather than a fresh synchronous snapshot), which
    /// is up to ~1s stale — see the note there for why that stays correct.
    private var streamedResume: [UUID: Data] = [:]

    /// Flush accumulated bytes to disk every 64 KiB. Seeds each transfer's
    /// ``TransferPlan/flushSize``.
    static let flushSize = 64 * 1024

    /// The per-host TCP connection ceiling for the session. `URLSession` defaults
    /// this to **6** on macOS — below the High profile's 16-way (and Medium's
    /// 8-way) segment fan-out, so without raising it the extra range connections
    /// to one host silently queue behind six and segmentation is capped at six.
    /// Set to the widest profile's per-server cap so the app's own
    /// ``ConnectionGovernor`` — not Foundation — is always the real limiter.
    /// (On HTTP/2 origins Foundation multiplexes over one connection regardless;
    /// this matters for the HTTP/1.1 file servers where segmentation actually
    /// helps.)
    static let maxConnectionsPerHost = 16

    /// Hard sanity cap on a single download's declared size, to reject an
    /// absurd server `Content-Length` that would trigger a huge preallocation.
    static let maxDownloadSize: Int64 = 100 * 1024 * 1024 * 1024 // 100 GB

    /// Sent on every request. Foundation's default `URLSession` emits no
    /// `User-Agent` for a plain data/bytes task (or an opaque CFNetwork one),
    /// and some CDNs / WAFs (e.g. Hetzner's edge) silently reset such
    /// connections — surfacing as `NSURLErrorNetworkConnectionLost (-1005)`
    /// even though the same URL works from `curl`. A real UA avoids that and
    /// identifies the client politely.
    static let userAgent = "GoelDownloader/1.0 (macOS)"

    /// Max attempts per request before giving up. Servers commonly cap the
    /// number of *concurrent* range connections per IP and answer the excess
    /// with `429 Too Many Requests` (Hetzner does); connections also drop
    /// transiently. A bounded exponential backoff lets a segment recover as
    /// sibling segments finish and free the server's connection budget,
    /// instead of failing the whole download. Validated against a server that
    /// admits only ~3 concurrent connections per IP.
    static let maxRequestAttempts = 10

    /// The config an unconfigured engine runs with. Deliberately mirrors the
    /// engine's historical hard-coded behaviour (full retry budget, built-in UA,
    /// no proxy, cookies on) so that, until `applyNetworkConfig` is called, the
    /// engine behaves exactly as before.
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

    /// Per-host credentials for protected downloads (preemptive Basic auth).
    /// `nonisolated` so the request builders off the actor can consult it.
    nonisolated let credentials: any CredentialProviding

    // MARK: Init

    /// Inject a fully-configured `URLSession` (used by tests with a stub
    /// `URLProtocol`).
    public init(session: URLSession, profile: TrafficProfile = .high,
                credentials: any CredentialProviding = KeychainCredentialStore()) {
        self.session = session
        self.profile = profile
        self.credentials = credentials
        self.downloadPacer = RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
    }

    /// Build a session from a configuration.
    init(configuration: URLSessionConfiguration, profile: TrafficProfile = .high,
                credentials: any CredentialProviding = KeychainCredentialStore()) {
        configuration.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost
        self.session = URLSession(configuration: configuration,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
        self.profile = profile
        self.credentials = credentials
        self.downloadPacer = RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
    }

    /// Default real-world session.
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

    // MARK: DownloadEngine

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
        // Persist the most recently STREAMED resume cursor. Unlike the old
        // synchronous snapshot this is up to ~1s stale, but resume re-validates
        // the remote's ETag / Last-Modified before reusing any stored range, so a
        // slightly old cursor stays correct (a changed remote simply restarts).
        if let data = streamedResume[id] {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
        tasks[id]?.status = .paused
        tasks[id]?.downloadSpeed = 0
        // A paused transfer has no open connections: clear the count so the detail
        // panel doesn't keep claiming e.g. "16 connections" while idle.
        tasks[id]?.connectionCount = 0
        // Note: the manager owns the .paused transition (it called pause()). We do
        // NOT echo .statusChanged(.paused) — a stale echo arriving after a later
        // resume would wrongly flip the task back to paused and strand it.
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
        // Drop the task from the map BEFORE the unwind suspension below: a
        // concurrent resume() (guarded on `tasks[id] != nil`) would otherwise slot
        // in a fresh job for a task we're tearing down, stranding a zombie job.
        tasks[id] = nil
        // Wait for the download task to actually unwind before deleting, so a
        // segment writer can't flush bytes to a path we've just unlinked.
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
        streamedResume[id] = nil
    }

    func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
        // The engine-wide pacer is long-lived (in-flight downloads already hold a
        // reference), so a profile change is retargeted in place rather than
        // waiting for the next transfer to build a fresh limiter.
        await downloadPacer.setRate(profile.maxDownloadBytesPerSec)
    }

    /// Apply network-layer settings. The bandwidth cap rides on `profile` (see
    /// `applyLimits`); this handles timeout, proxy, User-Agent, cookies and the
    /// retry budget. Session-level knobs require a brand-new `URLSession` because
    /// a `URLSessionConfiguration` is frozen once a session is built, so we copy
    /// the current configuration (preserving any injected protocol classes used
    /// by tests), mutate it, and swap the session. In-flight downloads keep the
    /// session they captured; the change takes effect on the next download.
    func applyNetworkConfig(_ config: HTTPNetworkConfig) async {
        self.networkConfig = config

        let cfg = session.configuration
        // Connection (idle) timeout. We intentionally do NOT lower
        // `timeoutIntervalForResource` to the same value — that caps the whole
        // transfer and would kill any download longer than `timeout` seconds.
        cfg.timeoutIntervalForRequest = config.timeout
        // Preserve the raised per-host connection ceiling across config swaps (a
        // fresh configuration would otherwise revert to Foundation's default of 6).
        cfg.httpMaximumConnectionsPerHost = Self.maxConnectionsPerHost

        var headers = cfg.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = config.userAgent
        cfg.httpAdditionalHeaders = headers

        cfg.httpShouldSetCookies = config.cookieAuthEnabled
        cfg.httpCookieAcceptPolicy = config.cookieAuthEnabled ? .always : .never
        cfg.httpCookieStorage = config.cookieAuthEnabled ? HTTPCookieStorage.shared : nil

        #if os(Linux)
        // The CFNetwork proxy-dictionary keys don't exist in swift-corelibs-foundation.
        // Honour a manual proxy via the standard http(s)_proxy environment variables,
        // which URLSession-on-Linux (libcurl-backed) already reads.
        switch config.proxyMode {
        case "manual" where !config.proxyHost.isEmpty && config.proxyPort > 0:
            let proxy = "http://\(config.proxyHost):\(config.proxyPort)"
            setenv("http_proxy", proxy, 1)
            setenv("https_proxy", proxy, 1)
        default:
            // "none" (explicit bypass) and "system" (fall back to ambient) both
            // must clear any manual proxy we set earlier — otherwise a manual→system
            // switch would silently keep routing every download (and libcurl's
            // FTP engine) through the stale proxy for the rest of the process.
            unsetenv("http_proxy"); unsetenv("https_proxy")
        }
        #else
        switch config.proxyMode {
        case "manual" where !config.proxyHost.isEmpty && config.proxyPort > 0:
            if config.proxyType == "socks5" {
                // A SOCKS proxy tunnels every scheme (http + https) through one hop.
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

        // Park the outgoing session rather than letting it be deallocated: freeing a
        // corelibs `URLSession` can abort the process (see ``SessionPool``). In-flight
        // probes keep running on it and finish normally.
        SessionPool.retire(session)

        // Rebuild the session with the SAME redirect sanitizer the initializers
        // install — a configuration copy never carries the delegate, so omitting
        // it here would silently drop cross-host `Authorization`/`Cookie`/`Referer`
        // stripping for the probe path (this runs on launch and every settings change).
        self.session = URLSession(configuration: cfg,
                                  delegate: RedirectSanitizer.shared, delegateQueue: nil)
    }

    /// Apply the HTTP network configuration (via the existing
    /// ``applyNetworkConfig(_:)``).
    func configure(_ net: HTTPNetworkConfig) async {
        await applyNetworkConfig(net)
    }

    func configureAggregation(_ config: AggregationEngineConfig) async {
        aggregationConfig = config
    }

    func configureFileConflictPolicy(_ policy: String) async {
        fileConflictPolicy = policy
    }

    /// Resolve a URL's name + size for the preview, adapting the concrete
    /// ``resolveMetadata(for:currentName:)`` probe to the engine-agnostic seam. The
    /// URL-derived base name mirrors the scheduler's default-name rule so a failed
    /// refinement returns the same fallback the manager would have chosen.
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

    // MARK: Driver

    private func run(_ id: UUID) async {
        guard let task = tasks[id], case .url(let url) = task.source else {
            let e = DownloadError.unknown("HTTPEngine requires a URL source")
            tasks[id]?.status = .failed(e)
            hub.fail(id, e)
            return
        }

        // Defense-in-depth: never write outside the save directory, even if a
        // hostile name slipped past upstream sanitisation.
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
                // On a resume/retry the partial file already holds the bytes
                // recorded in the resume cursor, so only the remaining tail needs
                // fresh space. Preflighting the full `total` would wrongly reject a
                // mostly-complete large download on a disk that can hold the
                // remainder but not the whole file again. Falls back to `total` when
                // there is no usable cursor (a genuinely fresh download).
                let alreadyOnDisk = Self.resumedBytesOnDisk(task.resumeData, total: total)
                try checkDiskSpace(task.saveDirectory, needed: max(0, total - alreadyOnDisk))
            }

            // Surface the real response facts (Server / ETag / Accept-Ranges /
            // Content-Type) so the Details tab shows live data, not placeholders.
            emit(id, .remoteInfoResolved(RemoteInfo(
                server: probe.server,
                etag: probe.etag,
                acceptRanges: probe.acceptsRanges,
                mimeType: probe.contentType
            )))

            // Refine the on-disk name now that response headers are known:
            // `Content-Disposition` supplies the real filename, `Content-Type` a
            // missing extension. Doing this before the first byte is written means
            // there is no partial file to move — which is also why it is confined to
            // a run that has downloaded nothing yet. `makeTask` resolves the on-disk
            // name conflict "at creation time only — never on resume/retry, which
            // reuse the stored name and rely on the partial file still living at the
            // same path"; this is the other half of that rule. On a resume the partial
            // already sits at `savePath`, so `PathSafety.uniqueName` would step OVER
            // it to a free name: the cursor's bytes would no longer be at the
            // destination, `SegmentedTransfer.destinationHoldsPreallocation` would
            // refuse the cursor, and every pause/resume cycle would restart from byte
            // zero under yet another name.
            let isFirstAttempt = task.resumeData == nil && task.bytesDownloaded == 0
            if isFirstAttempt,
               let better = Self.refinedName(current: task.name,
                                             suggestedName: probe.suggestedName,
                                             contentType: probe.contentType) {
                // Same policy leaf `makeTask` uses, so both name-resolution sites
                // obey the one "when a file exists" picker.
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

            // Per-request knobs captured once: the per-request settings (User-Agent,
            // retry budget) the off-actor byte pumps can't read from actor state.
            // Basic auth only ever rides over TLS (cleartext otherwise).
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

            // Resolve this download's connection count from the cross-download
            // budget and charge it to the aggregate accounting, releasing on EVERY
            // exit — clean completion, failure, or pause/remove cancellation. The
            // transfer itself owns no aggregate state, so the engine resolves the
            // count here and hands it down via the plan.
            let host = url.host
            let canSegment = probe.totalBytes != nil && probe.acceptsRanges
            var segmentCount = canSegment ? resolveSegmentCount(total: probe.totalBytes!, host: host) : 1

            // Multi-path: when aggregation is active and the server supports
            // ranges, open enough segments that each adapter gets real work.
            // (Previously we clamped to resolveSegmentCount's 64 KiB floor first,
            // which often collapsed to 1 segment → only one NIC was used.)
            // The task's own choice wins over the server-wide default; `.auto` (or
            // no choice at all) resolves back to whatever the policy decided.
            let resolution = AggregationPolicy.bindTargets(
                for: resolved.networkSelection,
                defaultAdapters: aggregationConfig.isActive ? aggregationConfig.adapters : [],
                available: aggregationConfig.available)
            if let note = resolution.note {
                GoelLog.engineHTTP.notice("Network selection adjusted", .detail(note))
            }
            let boundAdapters = resolution.adapters
            if boundAdapters.count >= 2, !canSegment {
                // ≥2 NICs resolved but the server hid range support: aggregation
                // cannot start. The mid-flight prober watches only when a size +
                // validator exist, so surface exactly what will happen instead of
                // an idle-NIC mystery.
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

            // Only the task's OWN limit rides on the plan: the profile ceiling is
            // enforced by `downloadPacer`, which every concurrent transfer shares so
            // the cap holds in sum. Folding them together here (the old
            // `effectiveDownloadCap`) gave each download a private copy of the
            // profile cap, so N downloads reached N × it.
            let maxBytesPerSecond = resolved.speedLimitBytesPerSec ?? 0

            // Mirror URLs ride along for the segmented path (the manager already
            // sanitized them to http/https, deduped, capped).
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
            // Mid-flight upgrade channel: attached unconditionally — the
            // transfer's own gate (size + validators + no range support) is
            // authoritative; plans built directly in tests default to nil.
            let extraGrants = ExtraGrantCounter()
            plan.requestExtraConnections = { [weak self] wanted in
                guard let self, wanted > 0 else { return 0 }
                let granted = await self.grantExtraConnections(host: host, wanted: wanted)
                extraGrants.add(granted)
                return granted
            }
            let planned = PlannedTransfer(plan: plan)

            // Charge the cross-download budget with the connection count the
            // transfer will ACTUALLY open, and release the same count on every
            // exit. The resume path may restore a different range count than the
            // freshly-resolved `segmentCount`, so reserve against the transfer's
            // resolved fan-out rather than `segmentCount`. `PlannedTransfer.init`
            // is synchronous, so the budget read above and this reservation remain
            // atomic on the actor (no suspension between them).
            let reserved = planned.connectionCount
            reserveConnections(host: host, count: reserved)
            // Balance to zero on EVERY exit: initial reservation + every mid-flight
            // grant (the grant closure records into `extraGrants` before it returns,
            // and it is only ever called from the transfer's main task, so every
            // grant happens-before this defer).
            defer { releaseConnections(host: host, count: reserved + extraGrants.total) }

            // Consume the transfer's progress on the actor: update our task and
            // re-emit the SAME EngineEvents as before (.progress, .fileProgress,
            // .resumeDataUpdated). The byte pumps run off-actor; this is the only
            // place transfer state crosses back onto the engine.
            let progressStream = planned.progress
            let consumer = Task { [weak self] in
                for await update in progressStream { await self?.applyProgress(id, update) }
            }

            let outcome: TransferOutcome
            do {
                outcome = try await planned.run()
                await consumer.value          // drain remaining progress before finishing
            } catch {
                consumer.cancel()
                await consumer.value
                throw error
            }

            try Task.checkCancellation()

            // Integrity check: when an expected hash was supplied, verify the
            // finished file before declaring success. `verify` is awaited so the
            // CPU-bound hashing runs off the actor; a mismatch throws
            // `.checksumMismatch`, which `DownloadError(mapping:)` passes straight
            // through to the catch block below.
            if let expected = task.expectedChecksum {
                tasks[id]?.downloadSpeed = 0
                tasks[id]?.status = .verifying
                emit(id, .statusChanged(.verifying))
                let matched = try await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)
                guard matched else { throw DownloadError.checksumMismatch }
            }

            // Final forced progress: the streamed ticks are throttled, so the last
            // flush may not have produced one — guarantee a 100% emit here. Clear
            // the live connection count first so the detail panel doesn't keep
            // showing open connections on a completed transfer.
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
            // Distinguish OUR cancellation (Task.isCancelled) from an EXTERNAL
            // URLSession cancel (VPN reset, OS preemption): the latter must not be
            // swallowed — it leaves the task stuck on "Downloading" forever.
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

    /// Bytes already persisted on disk for this download per its stored resume
    /// cursor, used to preflight only the REMAINING free space a resume/retry
    /// needs (the partial file already occupies the completed bytes). Returns 0 —
    /// so a fresh download still checks the full size — when there is no cursor,
    /// it doesn't decode, it describes a differently-sized remote, or it is
    /// arithmetic nonsense. `internal` so the untrusted-cursor guards below are
    /// assertable without driving a whole download.
    static func resumedBytesOnDisk(_ resumeData: Data?, total: Int64) -> Int64 {
        guard let data = resumeData,
              let cursor = try? JSONDecoder().decode(SegmentedTransfer.ResumeCursor.self, from: data),
              cursor.totalBytes == total else { return 0 }
        // Summed defensively: a cursor can arrive verbatim from an imported backup
        // envelope, and `reduce(0, +)` traps on `Int64` overflow. Anything
        // nonsensical reports 0, so the caller preflights the FULL size — the safe
        // direction, and the same "no usable cursor" answer as the guards above.
        var done: Int64 = 0
        for segment in cursor.completed {
            guard segment >= 0 else { return 0 }
            let (sum, overflowed) = done.addingReportingOverflow(segment)
            if overflowed { return 0 }
            done = sum
        }
        return min(done, max(0, total))
    }

    // Request building lives in `HTTPEngine+Requests.swift`.
    // Server probing + the metadata preview live in `HTTPEngine+Probe.swift`.
    // The cross-download connection budget lives in `HTTPEngine+Transfer.swift`;
    // the per-download byte mechanics live in `SegmentedTransfer.swift`.

    // MARK: Progress

    /// Apply one throttled progress tick from the running transfer: update the
    /// stored task and re-emit the engine's progress events. This is the single
    /// place a transfer's state crosses back onto the actor.
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

    // Disk preflight (ensureDirectory / checkDiskSpace / validateDiskSpace)
    // lives in `HTTPEngine+Disk.swift`.

    // MARK: Errors / events

    /// `internal` so the sibling-file extensions can publish events.
    nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }
}
