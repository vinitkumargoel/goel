import Foundation
import UniformTypeIdentifiers

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

    /// `var` (not `let`) because `applyNetworkConfig` swaps in a freshly built
    /// session: a `URLSessionConfiguration` is immutable once a session exists,
    /// so timeout / proxy / cookie / User-Agent changes require a new session.
    private var session: URLSession

    /// The active traffic profile. Drives the per-server segment count and the
    /// download bandwidth cap.
    private var profile: TrafficProfile

    /// Network-layer configuration (timeout / proxy / User-Agent / cookies and
    /// the retry budget). Applied to the `URLSession` and consumed by the retry
    /// path. Defaults preserve the engine's built-in behaviour until the manager
    /// pushes a config derived from the user's Network settings.
    private var networkConfig = HTTPEngine.defaultNetworkConfig

    /// Aggregate open-connection accounting across ALL concurrent downloads, so
    /// the profile's global `maxConnections` and per-host `maxConnectionsPerServer`
    /// caps hold in sum — not merely within a single task. Reserved when a
    /// download's segments start and released when it finishes / pauses / fails.
    private var totalConnections = 0
    private var connectionsByHost: [String: Int] = [:]

    // MARK: Per-task state

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]

    /// Bytes completed per segment index (the live download cursor).
    private var segmentBytes: [UUID: [Int: Int64]] = [:]
    private var connections: [UUID: Int] = [:]
    private var meters: [UUID: Meter] = [:]
    private var cursorMeta: [UUID: CursorMeta] = [:]
    private var lastResumeEmit: [UUID: Date] = [:]

    /// Flush accumulated bytes to disk every 64 KiB. `static` so the
    /// `nonisolated` streaming path can read it without crossing actor isolation.
    private static let flushSize = 64 * 1024

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

    // MARK: Requests

    /// Builds a request carrying the client `User-Agent`. `nonisolated` so the
    /// nonisolated segment/streaming paths can use it too. All outbound
    /// requests must go through here so none are sent UA-less.
    private nonisolated func makeRequest(_ url: URL, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// HTTP statuses worth retrying: explicit rate-limiting plus transient
    /// upstream/server errors.
    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    /// Network-level errors that a retry can plausibly recover from (a dropped
    /// connection, a timeout, a refused/transient host). Deliberately excludes
    /// `.cancelled` (our own pause/remove) and non-network errors (disk, etc.).
    static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Sleeps before the next attempt: honours a numeric `Retry-After` header
    /// when present, otherwise exponential backoff. Jitter de-synchronises a
    /// burst of segments that were all rate-limited at once (thundering herd).
    /// `Task.sleep` throws on cancellation, so pause/remove still interrupt.
    private nonisolated func backoff(attempt: Int, response: HTTPURLResponse?, retryInterval: Double) async throws {
        var seconds = min(6.0, pow(2.0, Double(attempt - 1)) * 0.4)
        // A configured retry interval acts as a floor on the wait (0 = leave the
        // built-in exponential backoff untouched).
        if retryInterval > 0 { seconds = max(seconds, retryInterval) }
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let advised = Double(header.trimmingCharacters(in: .whitespaces)) {
            seconds = min(15.0, max(seconds, advised))
        }
        seconds += Double.random(in: 0...0.4)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Metadata preview

    /// Probe a URL for the add-confirmation preview: returns the best filename
    /// (Content-Disposition / inferred extension) and the total size, plus whether
    /// the server was reachable. Performs the same HEAD/ranged-GET probe a real
    /// download would, but writes nothing and creates no task.
    public func resolveMetadata(for url: URL, currentName: String)
        async -> (name: String, totalBytes: Int64?, reachable: Bool) {
        guard let result = try? await probe(url) else {
            return (currentName, nil, false)
        }
        let refined = Self.refinedName(current: currentName,
                                       suggestedName: result.suggestedName,
                                       contentType: result.contentType)
        return (refined ?? currentName, result.totalBytes, true)
    }

    // MARK: Range-support probe

    private struct ProbeResult {
        var totalBytes: Int64?
        var acceptsRanges: Bool
        var etag: String?
        var lastModified: String?
        /// Filename from the `Content-Disposition` header, if the server sent one.
        var suggestedName: String?
        /// `Content-Type` MIME, used to infer an extension when the name lacks one.
        var contentType: String?
    }

    private func probe(_ url: URL) async throws -> ProbeResult {
        // Prefer a cheap HEAD.
        var head = makeRequest(url, userAgent: networkConfig.userAgent)
        head.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let r = interpretHead(http)
            // Only short-circuit when HEAD has already PROVEN range support. Many
            // servers carry Content-Length but emit `Accept-Ranges` on GET only;
            // for those, fall through to the ranged GET so a real 206 can still
            // unlock segmentation instead of silently dropping to one connection.
            if r.acceptsRanges { return r }
        }

        // Fall back to a one-byte ranged GET, which reveals both range support
        // (a 206 + Content-Range) and the total size.
        var get = makeRequest(url, userAgent: networkConfig.userAgent)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await session.data(for: get)
        guard let http = resp as? HTTPURLResponse else {
            throw DownloadError.network("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        return interpretRangedGet(http)
    }

    private func interpretHead(_ http: HTTPURLResponse) -> ProbeResult {
        let acceptsRanges = (header(http, "Accept-Ranges")?.lowercased() == "bytes")
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(
            totalBytes: length,
            acceptsRanges: acceptsRanges && length != nil,
            etag: header(http, "ETag"),
            lastModified: header(http, "Last-Modified"),
            suggestedName: Self.filename(fromContentDisposition: header(http, "Content-Disposition")),
            contentType: header(http, "Content-Type")
        )
    }

    private func interpretRangedGet(_ http: HTTPURLResponse) -> ProbeResult {
        let etag = header(http, "ETag")
        let lastModified = header(http, "Last-Modified")
        let suggestedName = Self.filename(fromContentDisposition: header(http, "Content-Disposition"))
        let contentType = header(http, "Content-Type")

        if http.statusCode == 206 {
            // "bytes 0-0/12345" -> 12345
            let total = header(http, "Content-Range")
                .flatMap { $0.split(separator: "/").last }
                .flatMap { Int64($0) }
            return ProbeResult(totalBytes: total, acceptsRanges: total != nil, etag: etag,
                               lastModified: lastModified, suggestedName: suggestedName, contentType: contentType)
        }

        // Server ignored the Range header and returned the whole body.
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(totalBytes: length, acceptsRanges: false, etag: etag,
                           lastModified: lastModified, suggestedName: suggestedName, contentType: contentType)
    }

    // MARK: Filename resolution (Content-Disposition / Content-Type)

    /// Parse a filename out of a `Content-Disposition` header. Prefers the
    /// RFC 5987 extended form (`filename*=UTF-8''…`, percent-decoded) and falls
    /// back to the plain `filename="…"`. Returns nil if the header is absent or
    /// carries no usable name. (Path components are stripped later by
    /// `sanitizedName`, so a hostile `filename="../x"` can't escape.)
    static func filename(fromContentDisposition header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        var plain: String?
        for token in header.components(separatedBy: ";") {
            let part = token.trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = String(part.dropFirst("filename*=".count))
                // charset'lang'pct-encoded  ->  take the part after the second quote.
                let encoded = value.range(of: "''").map { String(value[$0.upperBound...]) } ?? value
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded   // extended form wins outright
                }
            } else if lower.hasPrefix("filename=") {
                let value = String(part.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { plain = value }
            }
        }
        return plain
    }

    /// Preferred file extension for a MIME type (e.g. `video/mp4` -> `mp4`),
    /// stripping any `; charset=…` / `; codecs=…` parameters first.
    static func fileExtension(forMIME mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? mime
        guard !base.isEmpty, base != "application/octet-stream" else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }

    /// Compute a better on-disk name once response headers are known, or nil if
    /// the current name is already the best we can do. The server-supplied
    /// `Content-Disposition` name wins; otherwise the existing (URL-derived) name
    /// is kept but gains an extension inferred from `Content-Type` when it has
    /// none. The result is sanitized + length-clamped by `sanitizedName`.
    static func refinedName(current: String, suggestedName: String?, contentType: String?) -> String? {
        var name = current
        if let suggested = suggestedName {
            let cleaned = DownloadTask.sanitizedName(suggested, fallback: "")
            if !cleaned.isEmpty { name = cleaned }
        }
        if (name as NSString).pathExtension.isEmpty,
           let ext = fileExtension(forMIME: contentType) {
            name += "." + ext
        }
        let final = DownloadTask.sanitizedName(name, fallback: current)
        return final == current ? nil : final
    }

    private func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }

    // MARK: Segmented download

    private func segmentedDownload(id: UUID, url: URL, total: Int64, probe: ProbeResult, fileURL: URL, limiter: RateLimiter?, settings: RequestSettings) async throws {
        var ranges: [Range64]
        var restored: [Int: Int64] = [:]
        let host = url.host

        if let data = tasks[id]?.resumeData,
           let cursor = try? JSONDecoder().decode(ResumeCursor.self, from: data),
           cursor.totalBytes == total,
           validatorsMatch(cursor, probe) {
            // Remote unchanged: continue from where we left off.
            ranges = cursor.ranges
            for (i, done) in cursor.completed.enumerated() { restored[i] = done }
            try preallocate(fileURL, size: total)
        } else {
            // Fresh start (or remote changed): rebuild from scratch.
            let count = computeSegmentCount(total, host: host)
            ranges = makeRanges(total: total, count: count)
            try preallocate(fileURL, size: total)
        }

        // Charge this download's connections to the global / per-host budget and
        // release them on EVERY exit — clean completion, failure, or the task
        // group below unwinding on pause/remove cancellation.
        let reserved = ranges.count
        reserveConnections(host: host, count: reserved)
        defer { releaseConnections(host: host, count: reserved) }

        segmentBytes[id] = restored.isEmpty
            ? Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, Int64(0)) })
            : restored
        connections[id] = ranges.count
        tasks[id]?.connectionCount = ranges.count
        cursorMeta[id] = CursorMeta(etag: probe.etag, lastModified: probe.lastModified, total: total, ranges: ranges)

        let session = self.session
        // One governor per download: it begins at the requested fan-out and
        // adapts down to the server's real concurrent-connection ceiling.
        let governor = ConnectionGovernor(limit: ranges.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, range) in ranges.enumerated() {
                let already = segmentBytes[id]?[i] ?? 0
                let segStart = range.start + already
                if segStart > range.end { continue } // segment already complete
                group.addTask {
                    try await self.downloadSegment(session: session, governor: governor, limiter: limiter, settings: settings, id: id, url: url, index: i, from: segStart, to: range.end, fileURL: fileURL)
                }
            }
            try await group.waitForAll()
        }
    }

    /// `nonisolated` so the byte pump runs OFF the actor — otherwise every segment
    /// would serialize through the actor executor (one hop per byte), defeating the
    /// whole point of segmented downloading. It only hops back to the actor (via
    /// `await advance`) once per ~64 KiB flush.
    private nonisolated func downloadSegment(session: URLSession, governor: ConnectionGovernor, limiter: RateLimiter?, settings: RequestSettings, id: UUID, url: URL, index: Int, from start: Int64, to end: Int64, fileURL: URL) async throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        // Bytes of THIS segment already flushed to disk in this run. On a retry
        // we resume from `start + written`, so progress is never double-counted
        // and already-stored bytes are not re-fetched.
        var written: Int64 = 0
        var attempt = 0
        do {
            while start + written <= end {
                attempt += 1
                let segStart = start + written

                // Wait for a connection slot. The governor adapts the ceiling to
                // what the server actually tolerates (see ``ConnectionGovernor``).
                // Each `acquire()` below is balanced by exactly one `release()` on
                // every exit path of this attempt.
                await governor.acquire()
                var req = makeRequest(url, userAgent: settings.userAgent)
                req.setValue("bytes=\(segStart)-\(end)", forHTTPHeaderField: "Range")

                let bytes: URLSession.AsyncBytes
                let http: HTTPURLResponse
                do {
                    let (b, resp) = try await session.bytes(for: req)
                    guard let h = resp as? HTTPURLResponse else {
                        await governor.release(); throw DownloadError.network("No HTTP response")
                    }
                    bytes = b; http = h
                } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                    await governor.release()
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    continue
                } catch {
                    await governor.release(); throw error
                }

                if Self.isRetryableStatus(http.statusCode) {
                    for try await _ in bytes {}                       // drain the error body
                    await governor.throttleDown()                    // server pushed back: shrink the ceiling
                    await governor.release()
                    if attempt >= settings.maxAttempts { throw DownloadError.httpStatus(http.statusCode) }
                    try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                    continue
                }
                // Segments accept ONLY 206. A server that advertised range support
                // but answers a real ranged GET with 200 (full body) would have
                // every segment seek to its own offset and write the WHOLE file
                // there, overwriting siblings and corrupting the result. Reject it
                // as a clean, visible failure instead.
                guard http.statusCode == 206 else {
                    await governor.release(); throw DownloadError.httpStatus(http.statusCode)
                }

                do {
                    try handle.seek(toOffset: UInt64(segStart))
                    var buffer = Data()
                    buffer.reserveCapacity(Self.flushSize)
                    // Cooperative cancellation flows from the AsyncBytes iterator,
                    // so we check once per flush rather than once per byte (the
                    // latter burns ~16% of a core at speed for no added safety).
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= Self.flushSize {
                            try Task.checkCancellation()
                            try handle.write(contentsOf: buffer)
                            written += Int64(buffer.count)
                            await advance(id, segment: index, by: buffer.count)
                            // Pace against the profile's aggregate download cap.
                            // Shared across all segments, so combined throughput
                            // converges on the cap (no-op when unlimited).
                            await limiter?.pace(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    try Task.checkCancellation()
                    if !buffer.isEmpty {
                        try handle.write(contentsOf: buffer)
                        written += Int64(buffer.count)
                        await advance(id, segment: index, by: buffer.count)
                        await limiter?.pace(buffer.count)
                    }
                } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                    // Connection dropped mid-stream: back off and resume from the
                    // last flushed offset.
                    await governor.release()
                    try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                    continue
                } catch {
                    await governor.release(); throw error
                }

                await governor.release()
                break                                                // segment complete
            }
            // Close explicitly so a flush/close failure propagates and fails the
            // task, instead of reporting `.completed` over a half-flushed file.
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: Single-connection download

    private func singleDownload(id: UUID, url: URL, fileURL: URL, limiter: RateLimiter?, settings: RequestSettings) async throws {
        // SF8: truncate to zero on (re)create — `createFile` is a no-op when the
        // file already exists, which would leave stale trailing bytes if the new
        // download is shorter. `Data().write` both creates and truncates.
        try Data().write(to: fileURL)

        // A single connection still counts against the aggregate budget.
        let host = url.host
        reserveConnections(host: host, count: 1)
        defer { releaseConnections(host: host, count: 1) }

        segmentBytes[id] = [0: 0]
        connections[id] = 1
        tasks[id]?.connectionCount = 1
        cursorMeta[id] = nil

        try await streamSingle(session: session, limiter: limiter, settings: settings, id: id, url: url, fileURL: fileURL)
    }

    /// `nonisolated` single-connection body pump (see ``downloadSegment`` for why).
    private nonisolated func streamSingle(session: URLSession, limiter: RateLimiter?, settings: RequestSettings, id: UUID, url: URL, fileURL: URL) async throws {
        // Retry only the connect/status phase: the no-range fallback can't
        // resume a partial body, so a mid-stream drop fails (rather than
        // silently restarting and double-counting progress).
        var attempt = 0
        let bytes: URLSession.AsyncBytes
        while true {
            attempt += 1
            let req = makeRequest(url, userAgent: settings.userAgent)
            do {
                let (stream, resp) = try await session.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { throw DownloadError.network("No HTTP response") }
                if Self.isRetryableStatus(http.statusCode), attempt < settings.maxAttempts {
                    for try await _ in stream {}                     // drain the error body
                    try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else { throw DownloadError.httpStatus(http.statusCode) }
                bytes = stream
                break
            } catch let error where !(error is CancellationError) && Self.isTransient(error) && attempt < settings.maxAttempts {
                try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
                continue
            }
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            var buffer = Data()
            buffer.reserveCapacity(Self.flushSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.flushSize {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    await advance(id, segment: 0, by: buffer.count)
                    // Pace against the profile's download cap (no-op when unlimited).
                    await limiter?.pace(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                await advance(id, segment: 0, by: buffer.count)
                await limiter?.pace(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: Connection budget

    /// Charge `count` connections to the global and per-host budgets when a
    /// download's segments start. Balanced by `releaseConnections`.
    private func reserveConnections(host: String?, count: Int) {
        totalConnections += count
        if let host { connectionsByHost[host, default: 0] += count }
    }

    /// Return `count` connections to the budgets when a download ends (cleanly,
    /// by failure, or by pause/remove cancellation).
    private func releaseConnections(host: String?, count: Int) {
        totalConnections = max(0, totalConnections - count)
        if let host {
            let remaining = (connectionsByHost[host] ?? 0) - count
            if remaining > 0 { connectionsByHost[host] = remaining }
            else { connectionsByHost[host] = nil }
        }
    }

    // MARK: Segmenting

    private func computeSegmentCount(_ total: Int64, host: String?) -> Int {
        // The Low profile opts out of extra connections entirely (its
        // `enableExtraConnections` flag): one connection, no segmentation.
        guard profile.enableExtraConnections else { return 1 }
        var want = max(1, profile.maxConnectionsPerServer)
        // Share the per-server budget with any other in-flight download to the
        // same host, and the global budget across every concurrent download, so
        // the profile's advertised caps hold in aggregate (floor of 1 so a new
        // download never stalls with zero connections).
        let hostInUse = host.flatMap { connectionsByHost[$0] } ?? 0
        want = min(want, max(1, profile.maxConnectionsPerServer - hostInUse))
        want = min(want, max(1, profile.maxConnections - totalConnections))
        let minSegment: Int64 = 64 * 1024
        let bySize = max(1, Int((total + minSegment - 1) / minSegment))
        return max(1, min(want, bySize))
    }

    private func makeRanges(total: Int64, count: Int) -> [Range64] {
        guard total > 0 else { return [] }            // zero-byte file: nothing to fetch
        guard count > 0 else { return [Range64(start: 0, end: total - 1)] }
        let base = total / Int64(count)
        var ranges: [Range64] = []
        var start: Int64 = 0
        for i in 0..<count {
            let end = (i == count - 1) ? total - 1 : start + base - 1
            ranges.append(Range64(start: start, end: end))
            start = end + 1
        }
        return ranges
    }

    // MARK: Progress

    private func advance(_ id: UUID, segment: Int, by n: Int) {
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

    // MARK: Resume cursor

    private func maybeEmitResume(_ id: UUID, now: Date) {
        guard cursorMeta[id] != nil else { return }
        if now.timeIntervalSince(lastResumeEmit[id] ?? .distantPast) < 1.0 { return }
        lastResumeEmit[id] = now
        if let data = buildResumeData(id) {
            tasks[id]?.resumeData = data
            emit(id, .resumeDataUpdated(data))
        }
    }

    private func buildResumeData(_ id: UUID) -> Data? {
        guard let meta = cursorMeta[id] else { return nil }
        let completed = meta.ranges.indices.map { segmentBytes[id]?[$0] ?? 0 }
        let cursor = ResumeCursor(
            etag: meta.etag,
            lastModified: meta.lastModified,
            totalBytes: meta.total,
            ranges: meta.ranges,
            completed: completed
        )
        return try? JSONEncoder().encode(cursor)
    }

    private func validatorsMatch(_ cursor: ResumeCursor, _ probe: ProbeResult) -> Bool {
        Self.validatorsAllowResume(
            cursorETag: cursor.etag, cursorLastModified: cursor.lastModified,
            probeETag: probe.etag, probeLastModified: probe.lastModified
        )
    }

    /// Pure, testable resume-validation gate. If neither side offers an `ETag`
    /// nor a `Last-Modified`, there is nothing to verify the remote file is
    /// unchanged — so we DO NOT resume (a silent swap would corrupt the file);
    /// we restart from scratch instead.
    static func validatorsAllowResume(
        cursorETag: String?, cursorLastModified: String?,
        probeETag: String?, probeLastModified: String?
    ) -> Bool {
        if let a = cursorETag, let b = probeETag { return a == b }
        if let a = cursorLastModified, let b = probeLastModified { return a == b }
        return false
    }

    // MARK: Disk / filesystem

    private func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func checkDiskSpace(_ directory: String, needed: Int64) throws {
        try Self.validateDiskSpace(directory: directory, needed: needed)
    }

    /// Pure, testable disk-space gate. Rejects absurd sizes (cap), and — crucially
    /// — THROWS when the volume can't be queried instead of silently assuming
    /// unlimited space (which bypassed the guard entirely and let a multi-GB
    /// download start against a full disk).
    static func validateDiskSpace(
        directory: String,
        needed: Int64,
        maxAllowed: Int64 = HTTPEngine.maxDownloadSize
    ) throws {
        guard needed <= maxAllowed else {
            throw DownloadError.unknown("Declared size \(needed.byteString) exceeds the maximum allowed (\(maxAllowed.byteString))")
        }
        let url = URL(fileURLWithPath: directory)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw DownloadError.diskFull(needed: needed, available: 0)
        }
        if needed > available {
            throw DownloadError.diskFull(needed: needed, available: available)
        }
    }

    private func preallocate(_ url: URL, size: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

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

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    // MARK: Supporting types

    /// Per-request knobs captured once per download and threaded into the
    /// `nonisolated` byte pumps, which cannot read actor state per request.
    /// `Sendable` so it can cross into the segment task group.
    private struct RequestSettings: Sendable {
        var userAgent: String
        var maxAttempts: Int
        var retryInterval: Double
    }

    /// Two-point speed window: the time and byte-count at the previous emit.
    private struct Meter {
        var lastEmit: Date = .distantPast
        var lastEmitBytes: Int64 = 0
    }

    private struct Range64: Codable, Sendable {
        var start: Int64
        var end: Int64
    }

    private struct CursorMeta {
        var etag: String?
        var lastModified: String?
        var total: Int64
        var ranges: [Range64]
    }

    private struct ResumeCursor: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var totalBytes: Int64
        var ranges: [Range64]
        var completed: [Int64]
    }
}


// MARK: - Connection governor

/// Adaptive per-download concurrency limiter (decreasing).
///
/// Segmented downloads want many parallel connections for speed, but many
/// servers cap concurrent connections per client and answer the excess with
/// `429 Too Many Requests` (Hetzner admits only ~3). A fixed fan-out is wrong
/// either way: too low wastes bandwidth on permissive servers, too high gets
/// throttled on strict ones — and we cannot know the ceiling in advance.
///
/// So we *discover* it: start at the requested fan-out and shrink the ceiling
/// on every 429 (`throttleDown`). On a permissive server no 429s ever arrive
/// and the limit stays wide open; on a strict server it converges down to what
/// the server actually allows, so waiting segments simply queue instead of
/// hammering the server with doomed requests.
///
/// The limit is deliberately *monotonically decreasing* for the lifetime of a
/// download. Re-opening slots after a clean segment was tried and removed: it
/// pushes the limit back above the server's true ceiling, producing a fresh
/// 429, producing a re-open — a thrash that can exhaust a segment's retry
/// budget on a strict server. Re-probing belongs to a future, slower control
/// loop, not the hot path. The throughput cost is negligible because a
/// rate-limited server is the bottleneck regardless of how we slice it.
actor ConnectionGovernor {
    private var limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a connection slot is free, then claims it.
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by `pump()`, which already reserved the slot on our behalf.
    }

    /// Returns a slot and admits the next waiter if there is room.
    func release() {
        active = max(0, active - 1)
        pump()
    }

    /// The server signalled rate-limiting: lower the ceiling (floor of 1).
    func throttleDown() {
        if limit > 1 { limit -= 1 }
    }

    private func pump() {
        while active < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            active += 1                 // reserve on the waiter's behalf
            waiter.resume()
        }
    }
}

// MARK: - Network configuration

/// Network-layer settings pushed into the engine from the user's preferences.
/// The download bandwidth cap lives on `TrafficProfile` (see `applyLimits`); this
/// carries the rest: connection timeout, proxy, User-Agent, cookies and the retry
/// budget. Defaults match common product settings; the engine keeps its own,
/// behaviour-preserving default until `applyNetworkConfig` is called.
public struct HTTPNetworkConfig: Sendable, Equatable {
    public var timeout: Double
    public var retryCount: Int
    public var retryInterval: Double
    public var userAgent: String
    public var proxyMode: String   // none | system | manual
    public var proxyHost: String
    public var proxyPort: Int
    public var cookieAuthEnabled: Bool

    public init(
        timeout: Double = 30,
        retryCount: Int = 3,
        retryInterval: Double = 5,
        userAgent: String = "GoelDownloader/1.0 (macOS)",
        proxyMode: String = "none",
        proxyHost: String = "",
        proxyPort: Int = 0,
        cookieAuthEnabled: Bool = true
    ) {
        self.timeout = timeout
        self.retryCount = retryCount
        self.retryInterval = retryInterval
        self.userAgent = userAgent
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.cookieAuthEnabled = cookieAuthEnabled
    }
}

// MARK: - Rate limiter

/// Shared, actor-isolated download pacer that enforces the active profile's
/// AGGREGATE byte cap across all of a download's segments.
///
/// It reserves a slice of a virtual timeline of length `byteCount / rate` for
/// every flush. Because the timeline (`drainTime`) is shared and advanced
/// atomically before each sleep, concurrent segments queue behind one another
/// and their combined throughput converges on the cap — not `N ×` the cap. The
/// sleep happens after the bytes are already buffered, so the slowed reads exert
/// TCP backpressure on the sender. One limiter is created per download attempt
/// from the profile's current cap; a mid-download profile change takes effect on
/// the next (re)start. A cap of 0 means unlimited and no limiter is created.
actor RateLimiter {
    private let bytesPerSecond: Double
    /// Wall-clock instant by which all bytes reserved so far will have drained at
    /// the target rate.
    private var drainTime: Date

    init(bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.drainTime = Date()
    }

    /// Account for `byteCount` just delivered and sleep long enough to keep the
    /// shared rate at or below the cap. Cancellation-aware: a pause/remove during
    /// the sleep wakes it immediately (the caller's own checkCancellation reacts).
    func pace(_ byteCount: Int) async {
        guard bytesPerSecond > 0, byteCount > 0 else { return }
        let now = Date()
        // Idle gap: never bank credit for bytes that were not in flight.
        if drainTime < now { drainTime = now }
        drainTime = drainTime.addingTimeInterval(Double(byteCount) / bytesPerSecond)
        let delay = drainTime.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
