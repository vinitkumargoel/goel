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
public actor HTTPEngine: DownloadEngine {

    // MARK: Identity

    public nonisolated let kind: DownloadKind = .http

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

    /// Aggregate open-connection accounting across ALL concurrent downloads, so
    /// the profile's global `maxConnections` and per-host `maxConnectionsPerServer`
    /// caps hold in sum — not merely within a single task. Reserved when a
    /// download's segments start and released when it finishes / pauses / fails.
    var totalConnections = 0
    var connectionsByHost: [String: Int] = [:]

    // MARK: Per-task state

    var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    /// Bytes completed per segment index (the live download cursor).
    var segmentBytes: [UUID: [Int: Int64]] = [:]
    var connections: [UUID: Int] = [:]
    private var meters: [UUID: Meter] = [:]
    var cursorMeta: [UUID: CursorMeta] = [:]
    var lastResumeEmit: [UUID: Date] = [:]

    /// Flush accumulated bytes to disk every 64 KiB. `static` so the
    /// `nonisolated` streaming path can read it without crossing actor isolation.
    static let flushSize = 64 * 1024

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

    // MARK: Init

    /// Inject a fully-configured `URLSession` (used by tests with a stub
    /// `URLProtocol`).
    public init(session: URLSession, profile: TrafficProfile = .high) {
        self.session = session
        self.profile = profile
    }

    /// Build a session from a configuration.
    public init(configuration: URLSessionConfiguration, profile: TrafficProfile = .high) {
        self.session = URLSession(configuration: configuration)
        self.profile = profile
    }

    /// Default real-world session.
    public init(profile: TrafficProfile = .high) {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.profile = profile
    }

    // MARK: DownloadEngine

    public func add(_ task: DownloadTask) async {
        guard tasks[task.id] == nil else { return }
        tasks[task.id] = task
        meters[task.id] = Meter()
        let id = task.id
        jobs[id] = Task { await self.run(id) }
    }

    public func pause(_ id: DownloadTask.ID) async {
        guard let job = jobs[id] else { return }
        job.cancel()
        jobs[id] = nil
        if let data = buildResumeData(id) {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
        tasks[id]?.status = .paused
        tasks[id]?.downloadSpeed = 0
        // A paused transfer has no open connections: clear the count so the detail
        // panel doesn't keep claiming e.g. "16 connections" while idle.
        tasks[id]?.connectionCount = 0
        connections[id] = 0
        // Note: the manager owns the .paused transition (it called pause()). We do
        // NOT echo .statusChanged(.paused) — a stale echo arriving after a later
        // resume would wrongly flip the task back to paused and strand it.
    }

    public func resume(_ id: DownloadTask.ID) async {
        guard tasks[id] != nil, jobs[id] == nil else { return }
        meters[id] = Meter()
        emit(id, .statusChanged(.downloading))
        jobs[id] = Task { await self.run(id) }
    }

    public func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
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
        segmentBytes[id] = nil
        meters[id] = nil
        connections[id] = nil
        cursorMeta[id] = nil
        lastResumeEmit[id] = nil
    }

    public func applyLimits(_ profile: TrafficProfile) async {
        self.profile = profile
    }

    /// Apply network-layer settings. The bandwidth cap rides on `profile` (see
    /// `applyLimits`); this handles timeout, proxy, User-Agent, cookies and the
    /// retry budget. Session-level knobs require a brand-new `URLSession` because
    /// a `URLSessionConfiguration` is frozen once a session is built, so we copy
    /// the current configuration (preserving any injected protocol classes used
    /// by tests), mutate it, and swap the session. In-flight downloads keep the
    /// session they captured; the change takes effect on the next download.
    public func applyNetworkConfig(_ config: HTTPNetworkConfig) async {
        self.networkConfig = config

        let cfg = session.configuration
        // Connection (idle) timeout. We intentionally do NOT lower
        // `timeoutIntervalForResource` to the same value — that caps the whole
        // transfer and would kill any download longer than `timeout` seconds.
        cfg.timeoutIntervalForRequest = config.timeout

        var headers = cfg.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = config.userAgent
        cfg.httpAdditionalHeaders = headers

        cfg.httpShouldSetCookies = config.cookieAuthEnabled
        cfg.httpCookieAcceptPolicy = config.cookieAuthEnabled ? .always : .never
        cfg.httpCookieStorage = config.cookieAuthEnabled ? HTTPCookieStorage.shared : nil

        switch config.proxyMode {
        case "manual" where !config.proxyHost.isEmpty && config.proxyPort > 0:
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: config.proxyHost,
                kCFNetworkProxiesHTTPPort as String: config.proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: config.proxyHost,
                kCFNetworkProxiesHTTPSPort as String: config.proxyPort,
            ]
        case "none":
            cfg.connectionProxyDictionary = [:]   // explicitly bypass any proxy
        default:
            cfg.connectionProxyDictionary = nil   // "system": follow OS proxy settings
        }

        self.session = URLSession(configuration: cfg)
    }

    public func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        guard var task = tasks[id] else { return }
        if let idx = task.files.firstIndex(where: { $0.id == fileID }) {
            task.files[idx].priority = priority
            tasks[id] = task
        }
    }

    public nonisolated func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }

    // MARK: Driver

    private func run(_ id: UUID) async {
        guard let task = tasks[id], case .url(let url) = task.source else {
            let e = DownloadError.unknown("HTTPEngine requires a URL source")
            tasks[id]?.status = .failed(e)
            emit(id, .failed(e))
            emit(id, .statusChanged(.failed(e)))
            return
        }

        // Defense-in-depth: never write outside the save directory, even if a
        // hostile name slipped past upstream sanitisation.
        guard task.isSavePathContained else {
            let e = DownloadError.unknown("Path traversal blocked")
            tasks[id]?.status = .failed(e)
            jobs[id] = nil
            emit(id, .failed(e))
            emit(id, .statusChanged(.failed(e)))
            return
        }

        tasks[id]?.status = .downloading
        emit(id, .statusChanged(.downloading))

        do {
            try ensureDirectory(task.saveDirectory)
            let probe = try await probe(url)

            if let total = probe.totalBytes {
                try checkDiskSpace(task.saveDirectory, needed: total)
            }

            // Refine the on-disk name now that response headers are known:
            // `Content-Disposition` supplies the real filename, `Content-Type` a
            // missing extension. Doing this before the first byte is written means
            // there is no partial file to move. On a resume the server returns the
            // same name, so `refinedName` is a no-op and the existing partial (kept
            // under the already-resolved name) is reused untouched.
            if let better = Self.refinedName(current: task.name,
                                             suggestedName: probe.suggestedName,
                                             contentType: probe.contentType) {
                let unique = DownloadTask.uniqueName(base: better, in: task.saveDirectory)
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
                emit(id, .failed(e))
                emit(id, .statusChanged(.failed(e)))
                return
            }
            let fileURL = URL(fileURLWithPath: resolved.savePath)

            // Per-download knobs captured once: the aggregate-rate pacer (honours
            // the profile's download cap; nil when unlimited) and the per-request
            // settings (User-Agent, retry budget) the `nonisolated` byte pumps
            // can't read from actor state on their own.
            let limiter = profile.maxDownloadBytesPerSec > 0
                ? RateLimiter(bytesPerSecond: profile.maxDownloadBytesPerSec)
                : nil
            let settings = RequestSettings(
                userAgent: networkConfig.userAgent,
                maxAttempts: networkConfig.retryCount,
                retryInterval: networkConfig.retryInterval
            )

            if let total = probe.totalBytes {
                tasks[id]?.totalBytes = total
                emit(id, .metadataResolved(
                    name: resolved.name,
                    totalBytes: total,
                    files: [TransferFile(id: 0, path: resolved.name, length: total)]
                ))
                if probe.acceptsRanges {
                    try await segmentedDownload(id: id, url: url, total: total, probe: probe, fileURL: fileURL, limiter: limiter, settings: settings)
                } else {
                    try await singleDownload(id: id, url: url, fileURL: fileURL, limiter: limiter, settings: settings)
                }
            } else {
                // No Content-Length: stream a single connection, leave totalBytes nil.
                try await singleDownload(id: id, url: url, fileURL: fileURL, limiter: limiter, settings: settings)
            }

            try Task.checkCancellation()

            // Integrity check: when an expected hash was supplied, verify the
            // finished file before declaring success. `verify` is awaited so the
            // CPU-bound hashing runs off the actor; a mismatch throws
            // `.checksumMismatch`, which `mapError` passes straight through to the
            // catch block below.
            if let expected = task.expectedChecksum {
                tasks[id]?.downloadSpeed = 0
                tasks[id]?.status = .verifying
                emit(id, .statusChanged(.verifying))
                let matched = try await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)
                guard matched else { throw DownloadError.checksumMismatch }
            }

            // Finished: clear the live connection count BEFORE the final progress
            // emit so the detail panel doesn't keep showing open connections on a
            // completed transfer.
            connections[id] = 0
            tasks[id]?.connectionCount = 0
            forceProgress(id)
            tasks[id]?.status = .completed
            tasks[id]?.completedAt = Date()
            tasks[id]?.downloadSpeed = 0
            jobs[id] = nil
            emit(id, .finished)
            emit(id, .statusChanged(.completed))
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
                de = mapError(error)
            }
            tasks[id]?.status = .failed(de)
            tasks[id]?.downloadSpeed = 0
            jobs[id] = nil
            emit(id, .failed(de))
            emit(id, .statusChanged(.failed(de)))
        }
    }

    // Request building & retry policy live in `HTTPEngine+Requests.swift`.
    // Server probing + the metadata preview live in `HTTPEngine+Probe.swift`.
    // The transfer mechanics (segmented / single / budget / segmenting) live in
    // `HTTPEngine+Transfer.swift`.

    // MARK: Progress

    /// `internal` so the `+Transfer` byte pumps can report flushed bytes.
    func advance(_ id: UUID, segment: Int, by n: Int) {
        guard tasks[id] != nil else { return }
        segmentBytes[id, default: [:]][segment, default: 0] += Int64(n)
        recordAndEmit(id)
    }

    private func recordAndEmit(_ id: UUID) {
        guard tasks[id] != nil else { return }
        let total = segmentBytes[id]?.values.reduce(0, +) ?? 0
        tasks[id]?.bytesDownloaded = total

        let now = Date()
        var meter = meters[id] ?? Meter()
        guard now.timeIntervalSince(meter.lastEmit) > 0.1 else { return }

        // O(1) two-point sliding window: speed since the previous emit. No growing
        // sample array to scan/trim on every flush.
        let dt = now.timeIntervalSince(meter.lastEmit)
        let speed = (dt > 0 && dt < 3600) ? Double(total - meter.lastEmitBytes) / dt : 0
        meter.lastEmit = now
        meter.lastEmitBytes = total
        meters[id] = meter

        tasks[id]?.downloadSpeed = speed
        emit(id, .progress(
            bytesDownloaded: total,
            bytesUploaded: 0,
            downloadSpeed: speed,
            uploadSpeed: 0,
            connectionCount: connections[id] ?? 1
        ))
        emit(id, .fileProgress(fileID: 0, bytesCompleted: total))
        maybeEmitResume(id, now: now)
    }

    private func forceProgress(_ id: UUID) {
        if meters[id] == nil { meters[id] = Meter() }
        meters[id]?.lastEmit = .distantPast
        recordAndEmit(id)
    }

    // The resume cursor (maybeEmitResume / buildResumeData / validators) and its
    // Range64 / CursorMeta / ResumeCursor types live in `HTTPEngine+Resume.swift`.
    // Disk preflight (ensureDirectory / checkDiskSpace / validateDiskSpace /
    // preallocate) lives in `HTTPEngine+Disk.swift`.

    // MARK: Errors / events

    private func mapError(_ error: Error) -> DownloadError {
        if let de = error as? DownloadError { return de }
        if let ue = error as? URLError {
            switch ue.code {
            case .timedOut: return .timedOut
            case .cancelled: return .canceled
            case .fileDoesNotExist: return .fileMissing
            default: return .network(ue.localizedDescription)
            }
        }
        return .network((error as NSError).localizedDescription)
    }

    /// `internal` so the `+Resume` extension can publish resume-data events.
    nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    // MARK: Supporting types

    /// Per-request knobs captured once per download and threaded into the
    /// `nonisolated` byte pumps, which cannot read actor state per request.
    /// `Sendable` so it can cross into the segment task group. `internal` so the
    /// `+Transfer` byte pumps (in a sibling file) can take it as a parameter.
    struct RequestSettings: Sendable {
        var userAgent: String
        var maxAttempts: Int
        var retryInterval: Double
    }

    /// Two-point speed window: the time and byte-count at the previous emit.
    private struct Meter {
        var lastEmit: Date = .distantPast
        var lastEmitBytes: Int64 = 0
    }
}
