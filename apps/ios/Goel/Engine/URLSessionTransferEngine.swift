import Foundation
import Network
import OSLog
import Synchronization

// MARK: - TokenBucket

/// One shared rate limiter for every connection of every download.
///
/// A per-connection cap is the wrong shape: six connections each limited to 1 MB/s is a 6 MB/s
/// download, and the user asked for 1. So the bucket is shared, and `reserve` is allowed to go
/// into debt — the caller that pushed it negative pays the wait, which is what keeps the long-run
/// average exactly at the configured rate instead of somewhere below it.
///
/// The clock is injectable so the arithmetic can be tested without sleeping.
public actor TokenBucket {

    private var rate: Int64?
    private var available: Double
    private var lastRefill: Double
    private let clock: @Sendable () -> Double

    /// Monotonic seconds. `Date()` would let a clock adjustment hand out unlimited tokens.
    public static let monotonicClock: @Sendable () -> Double = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public init(rate: Int64?, clock: @escaping @Sendable () -> Double = TokenBucket.monotonicClock) {
        self.rate = rate
        self.clock = clock
        self.available = Double(rate ?? 0)
        self.lastRefill = clock()
    }

    /// `nil` means unlimited. Takes effect on connections that are already running, because it
    /// changes the bucket every one of them is drawing from — that is why `applyTuning` does not
    /// need to restart anything to change the speed cap.
    public func setRate(_ newRate: Int64?) {
        refill()
        rate = newRate
        if let newRate {
            available = min(available, Double(newRate))
        } else {
            available = 0
        }
    }

    public func currentRate() -> Int64? { rate }

    /// Deducts `count` tokens and returns how many seconds the caller must wait before spending
    /// them. `0` when unlimited or when the bucket had enough.
    public func reserve(_ count: Int) -> Double {
        guard let rate, rate > 0, count > 0 else { return 0 }
        refill()
        available -= Double(count)
        guard available < 0 else { return 0 }
        let wait = -available / Double(rate)
        return wait.isFinite ? max(0, wait) : 0
    }

    private func refill() {
        let now = clock()
        defer { lastRefill = now }
        guard let rate, rate > 0 else { return }
        let elapsed = max(0, now - lastRefill)
        // Burst capacity is one second of the configured rate: enough to keep a 128 KB write
        // from stalling on a fast link, small enough that the cap is not visibly overshot.
        available = min(Double(rate), available + elapsed * Double(rate))
    }
}

// MARK: - SegmentPlan

/// The split arithmetic, isolated from everything that does I/O.
///
/// Off-by-one here is the classic bug in a segmented downloader and it does not announce itself:
/// the file is the right length, the progress bar reaches 100 %, and the checksum is wrong. So
/// every function here is pure and every one of them is unit-tested against a size that is *not*
/// a multiple of the connection count.
public enum SegmentPlan {

    /// The mockup draws six segment bars; six is also where the throughput curve flattens on a
    /// typical mobile link. A named constant, never a literal at a call site.
    public static let defaultConnectionCount = 6

    /// Below this, segmentation costs more in round trips than it wins in parallelism.
    public static let segmentationThreshold: Int64 = 8 * 1024 * 1024

    /// Sequential mode's work unit. Small enough that the playable prefix advances smoothly,
    /// large enough that a 200 MB file is fifty blocks rather than fifty thousand.
    public static let sequentialBlockSize: Int64 = 4 * 1024 * 1024

    public static func length(of range: ClosedRange<Int64>) -> Int64 {
        range.upperBound - range.lowerBound + 1
    }

    /// How many connections a download gets. `1` whenever segmentation is impossible or
    /// pointless — no ranges, no known length, or a file below the threshold.
    ///
    /// The traffic profile is a ceiling as well as a default: "Conservative" means two
    /// connections even if the connection slider is at eight.
    public static func connectionCount(
        tuning: EngineTuning,
        totalBytes: Int64?,
        supportsResume: Bool
    ) -> Int {
        guard supportsResume, let total = totalBytes, total >= segmentationThreshold else { return 1 }
        let ceiling = min(tuning.maxConnections, tuning.trafficProfile.connections)
        return max(1, min(ceiling, 8))
    }

    /// Splits one inclusive range into `count` inclusive ranges that cover it exactly: no gap, no
    /// overlap, no zero-length segment. The remainder is spread one byte at a time over the
    /// leading segments rather than dumped on the last one.
    public static func split(_ range: ClosedRange<Int64>, into count: Int) -> [ClosedRange<Int64>] {
        let total = length(of: range)
        guard total > 0 else { return [] }
        // Never more segments than bytes — a zero-length segment would produce `bytes=n-(n-1)`,
        // which is a malformed Range header and a 416 from a correct server.
        let parts = Int64(max(1, min(Int64(max(count, 1)), total)))
        let base = total / parts
        let remainder = total % parts

        var out: [ClosedRange<Int64>] = []
        out.reserveCapacity(Int(parts))
        var lower = range.lowerBound
        for index in 0..<parts {
            let size = base + (index < remainder ? 1 : 0)
            let upper = lower + size - 1
            out.append(lower...upper)
            lower = upper + 1
        }
        return out
    }

    /// Ordered, fixed-size blocks covering `range`. The tail block is short, never zero-length.
    public static func blocks(_ range: ClosedRange<Int64>, size: Int64) -> [ClosedRange<Int64>] {
        let blockSize = max(1, size)
        var out: [ClosedRange<Int64>] = []
        var lower = range.lowerBound
        while lower <= range.upperBound {
            let upper = min(lower + blockSize - 1, range.upperBound)
            out.append(lower...upper)
            lower = upper + 1
        }
        return out
    }

    /// Block size for a sequential transfer: `sequentialBlockSize`, grown for very large files so
    /// the block list stays bounded.
    public static func sequentialBlockSize(forTotal total: Int64) -> Int64 {
        max(sequentialBlockSize, total / 512)
    }

    /// The work list for a download, given the holes that still need filling.
    ///
    /// **Sequential mode** (`isSequential`, which T10's play-while-downloading depends on) does
    /// not hand each worker a sixth of the file. It lays the remaining bytes out as ordered
    /// blocks and every worker takes the *lowest* one still unclaimed — see
    /// ``URLSessionTransferEngine`` for the claim rule. The in-flight window is therefore always
    /// the N blocks immediately after the completed prefix: bytes `0…n` stay contiguous and the
    /// file is playable while it is still arriving, while N connections are still in flight.
    ///
    /// **Parallel mode** splits each hole into as many pieces as there are connections to spare.
    public static func plan(
        gaps: [ClosedRange<Int64>],
        connections: Int,
        isSequential: Bool
    ) -> [ClosedRange<Int64>] {
        let gaps = gaps.filter { length(of: $0) > 0 }.sorted { $0.lowerBound < $1.lowerBound }
        guard !gaps.isEmpty else { return [] }

        if isSequential {
            let remaining = gaps.reduce(Int64(0)) { $0 + length(of: $1) }
            let size = sequentialBlockSize(forTotal: remaining)
            return gaps.flatMap { blocks($0, size: size) }
        }

        let connections = max(1, connections)
        guard connections > 1, gaps.count < connections else { return gaps }
        let perGap = max(1, Int((Double(connections) / Double(gaps.count)).rounded(.up)))
        return gaps.flatMap { split($0, into: perGap) }.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// 0.5 s, 1 s, 2 s — plus a small deterministic spread derived from the claim id so six
    /// segments that all fail on the same dropped Wi-Fi do not all retry on the same millisecond.
    /// Deterministic rather than random so a failing test is reproducible.
    public static func backoffDelay(attempt: Int, seed: Int) -> Double {
        let capped = min(max(attempt, 1), 6)
        let base = 0.5 * pow(2, Double(capped - 1))
        let spread = Double((seed &* 37) % 100) / 1000.0
        return base + spread
    }
}

// MARK: - HTTPChunkFeed

/// A `URLSessionDataTask` presented as an `AsyncThrowingStream` of `Data` chunks, with real
/// backpressure.
///
/// `URLSession.bytes(for:)` would be less code, but it delivers one `UInt8` per `await` — two
/// hundred million suspension points for a 200 MB file. A data task delivers whatever the socket
/// produced, which is what we want to `pwrite`.
///
/// The catch is that `didReceive data:` has no way to say "slow down", so an unbounded stream
/// buffers the whole file in memory whenever the consumer is slower than the network — and the
/// consumer *is* slower whenever a speed limit is set. So this counts unwritten bytes and
/// `suspend()`s the task above a high-water mark, resuming it once the engine has drained below
/// half of it.
///
/// `Sendable` here is genuine, not `@unchecked`: every stored property is a `let`, and the only
/// mutable state lives inside a `Mutex`.
final class HTTPChunkFeed: NSObject, URLSessionDataDelegate, Sendable {

    enum Element: Sendable {
        case response(HTTPURLResponse)
        case chunk(Data)
    }

    let stream: AsyncThrowingStream<Element, any Error>

    private let continuation: AsyncThrowingStream<Element, any Error>.Continuation
    private let task: URLSessionDataTask
    private let highWater: Int
    private let state = Mutex<Backpressure>(Backpressure())

    private struct Backpressure {
        var unwritten = 0
        var isSuspended = false
    }

    init(session: URLSession, request: URLRequest, highWater: Int) {
        let task = session.dataTask(with: request)
        self.task = task
        self.highWater = max(highWater, 64 * 1024)
        let (stream, continuation) = AsyncThrowingStream<Element, any Error>.makeStream(
            of: Element.self,
            throwing: (any Error).self,
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.continuation = continuation
        super.init()
        task.delegate = self
        continuation.onTermination = { @Sendable _ in task.cancel() }
        task.resume()
    }

    /// Called by the engine once bytes have actually reached the file, releasing backpressure.
    func consumed(_ count: Int) {
        guard count > 0 else { return }
        let shouldResume = state.withLock { pressure -> Bool in
            pressure.unwritten = max(0, pressure.unwritten - count)
            guard pressure.isSuspended, pressure.unwritten <= highWater / 2 else { return false }
            pressure.isSuspended = false
            return true
        }
        if shouldResume { task.resume() }
    }

    func cancel() {
        continuation.finish()
        task.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            continuation.yield(.response(http))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.chunk(data))
        let shouldSuspend = state.withLock { pressure -> Bool in
            pressure.unwritten += data.count
            guard !pressure.isSuspended, pressure.unwritten >= highWater else { return false }
            pressure.isSuspended = true
            return true
        }
        if shouldSuspend { dataTask.suspend() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - URLSessionTransferEngine

/// The real one. Segmented, resumable, rate-limited HTTP over `URLSession`.
///
/// Six connections write into **one** preallocated sparse file at their own offsets. Not six temp
/// files and a concatenation pass: that doubles peak disk on a device that has none to spare, and
/// it makes T10's play-while-downloading impossible because there is no single file to play until
/// the very end.
///
/// State lives in one `jobs` dictionary on the actor. Workers are child tasks that call back into
/// the actor to claim ranges and record bytes, so every mutation of that dictionary is serialised
/// by actor isolation and the only thing that happens off-actor is the network read itself.
public actor URLSessionTransferEngine: TransferEngine {

    // MARK: Events

    public nonisolated let events: AsyncStream<TransferEvent>
    private nonisolated let continuation: AsyncStream<TransferEvent>.Continuation

    // MARK: Tunables

    /// At most 10 progress events per second per download. A `.progress` per chunk floods the
    /// main actor — six connections at 128 KB on a fast link is thousands of events a second, and
    /// SwiftUI drops frames long before it drops events.
    static let progressInterval: Duration = .milliseconds(100)
    /// The cursor sidecar is rewritten at most this often, plus at every state transition. Losing
    /// one interval of cursor costs a second of re-downloaded bytes, never a corrupt file.
    static let checkpointInterval: Duration = .seconds(1)
    /// Batching thresholds for the cellular byte counter — see `noteCellularBytes`.
    static let cellularFlushBytes: Int64 = 8 * 1024 * 1024
    static let cellularFlushInterval: Duration = .seconds(10)
    /// Attempts on one range by one connection before the range is handed to another connection.
    static let maxAttemptsPerRange = 3

    // MARK: Collaborators

    private let store: FileStore
    private let session: URLSession
    private let bucket: TokenBucket
    private let coordinator: BackgroundCoordinator?
    private let monitorsNetworkPath: Bool
    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "engine")

    // MARK: State

    private var tuning: EngineTuning
    private var jobs: [UUID: Job] = [:]
    private var verifiedChecksums: [UUID: Bool] = [:]
    private var monitor: NWPathMonitor?
    private var isCellular = false
    private var isExpensive = false
    private var didAttach = false
    /// Cellular bytes seen since the last write-through to ``CellularDataLedger``.
    private var cellularBytesPending: Int64 = 0
    private var lastCellularFlush = ContinuousClock.now

    // MARK: - Job

    /// One range of a download that a connection has taken responsibility for.
    struct ActiveClaim: Sendable {
        var range: ClosedRange<Int64>
        /// Bytes written, always a contiguous run forward from `range.lowerBound`. This is what
        /// makes `Download.Segment.cursor` meaningful and what the checkpoint records.
        var received: Int64
        var attempts: Int
        /// This range has already been abandoned by one connection and picked up by another.
        var handedOff: Bool
    }

    struct PendingRange: Sendable, Equatable {
        var range: ClosedRange<Int64>
        var attempts: Int = 0
        var handedOff: Bool = false
    }

    private struct Job {
        var download: Download
        var destination: URL
        var part: URL
        var checkpoint: URL
        var file: SparseFile?
        /// Merged, sorted, non-overlapping. Bytes that are definitely on disk.
        var completed: [ClosedRange<Int64>] = []
        var active: [Int: ActiveClaim] = [:]
        var pending: [PendingRange] = []
        var nextClaimID = 0
        var connections = 1
        var runner: Task<Void, Never>?
        var isPaused = false
        var isCancelled = false
        var failure: TransferError?
        var handedToBackground = false
        var lastEmit: ContinuousClock.Instant
        var lastCheckpoint: ContinuousClock.Instant
        var bytesSinceEmit: Int64 = 0
    }

    private enum ClaimOutcome { case done, stop }
    private enum Attempt { case retry(Double), handOff, fail }

    // MARK: - Life cycle

    /// - Parameters:
    ///   - fileStore: injected by tests so a download never touches the real container.
    ///   - backgroundCoordinator: `nil` disables the T06 handoff. Passing `nil` is what lets this
    ///     engine be driven from a command-line harness, where there is no app to be relaunched.
    public init(
        fileStore: FileStore = FileStore(),
        tuning: EngineTuning = .default,
        session: URLSession? = nil,
        monitorsNetworkPath: Bool = true,
        backgroundCoordinator: BackgroundCoordinator? = BackgroundCoordinator.shared
    ) {
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream(
            of: TransferEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        self.events = stream
        self.continuation = continuation
        self.store = fileStore
        self.tuning = tuning
        self.bucket = TokenBucket(rate: tuning.speedLimitBytesPerSec)
        self.coordinator = backgroundCoordinator
        self.monitorsNetworkPath = monitorsNetworkPath

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 8
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 7 * 24 * 60 * 60
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.waitsForConnectivity = true
            config.allowsCellularAccess = true
            self.session = URLSession(configuration: config)
        }

        Task { await self.attach() }
    }

    deinit {
        continuation.finish()
    }

    private func attach() {
        guard !didAttach else { return }
        didAttach = true
        coordinator?.configure(store: store)
        coordinator?.setObserver { [weak self] event in
            Task { await self?.handleBackgroundEvent(event) }
        }
        startPathMonitor()
    }

    // MARK: - Cellular policy

    /// Whether the current network path forces a download to stand down, and into which state.
    ///
    /// A pure function so it can be tested without a radio: PRD §4.1's promise is that we never
    /// *fail* a download for being on cellular, we park it and say so.
    public static func policyStatus(
        isCellular: Bool,
        isExpensive: Bool,
        tuning: EngineTuning
    ) -> Download.Status? {
        guard !tuning.allowCellular else { return nil }
        return (isCellular || isExpensive) ? .waitingForWiFi : nil
    }

    private func startPathMonitor() {
        guard monitorsNetworkPath, monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Extract the two booleans on the monitor's own queue: `NWPath` does not cross
            // isolation, and these are the only two facts the policy needs.
            let cellular = path.usesInterfaceType(.cellular)
            let expensive = path.isExpensive
            Task { await self?.pathChanged(isCellular: cellular, isExpensive: expensive) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.goel.ios.path", qos: .utility))
        monitor = pathMonitor
    }

    private func pathChanged(isCellular: Bool, isExpensive: Bool) async {
        self.isCellular = isCellular
        self.isExpensive = isExpensive
        let blocked = Self.policyStatus(isCellular: isCellular, isExpensive: isExpensive, tuning: tuning)
        for (id, job) in jobs {
            if let blocked {
                guard !job.isPaused, job.failure == nil, job.download.status != blocked else { continue }
                park(id, status: blocked)
            } else if job.download.status == .waitingForWiFi {
                await resume(id)
            }
        }
    }

    /// Stops the connections but keeps the job and its bytes, and tells the UI why.
    private func park(_ id: UUID, status: Download.Status) {
        guard var job = jobs[id] else { return }
        let runner = job.runner
        job.runner = nil
        job.isPaused = true
        job.download.status = status
        jobs[id] = job
        runner?.cancel()
        writeCheckpoint(id)
        continuation.yield(.statusChanged(id: id, status: status))
    }

    // MARK: - Tuning

    /// Applies immediately to transfers already in flight — that is the whole point of a shared
    /// token bucket and of re-reading `chunkSize` per write. Connection *count* is the one
    /// exception: adding a seventh connection means splitting a range that a running task is
    /// already streaming, so it takes effect on the next `start`/`resume`.
    public func applyTuning(_ tuning: EngineTuning) async {
        self.tuning = tuning
        await bucket.setRate(tuning.speedLimitBytesPerSec)
        await pathChanged(isCellular: isCellular, isExpensive: isExpensive)
    }

    /// Whether a finished download's SHA-256 matched a sidecar digest.
    ///
    /// ``TransferEvent`` has no field for this and that enum is the app's frozen seam, so the
    /// result is queryable here rather than pushed. `false` means "not verified", which includes
    /// "there was no sidecar" — we never claim a verification we did not perform.
    /// Protocol spelling; see `checksumVerified(_:)`.
    public func checksumWasVerified(_ id: UUID) async -> Bool { checksumVerified(id) }

    public func checksumVerified(_ id: UUID) -> Bool {
        verifiedChecksums[id] ?? false
    }

    // MARK: - Probe

    private static let supportedSchemes: Set<String> = ["http", "https"]

    public func probe(_ url: URL) async throws -> ProbeResult {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, url.host != nil else {
            throw TransferError.invalidURL
        }
        guard Self.supportedSchemes.contains(scheme) else {
            throw TransferError.unsupportedScheme(scheme)
        }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        head.timeoutInterval = 30

        var response: HTTPURLResponse?
        do {
            let (_, raw) = try await session.data(for: head)
            response = raw as? HTTPURLResponse
        } catch {
            // A server that hangs up on HEAD is common enough (some CDNs, most FTP-over-HTTP
            // gateways) that it is not a failure yet — fall through to the ranged GET.
            log.debug("HEAD failed for \(url.absoluteString, privacy: .public), falling back to ranged GET")
            response = nil
        }

        // 405/501 are the honest rejections; 400/403 are what a badly configured server sends
        // instead. All four mean "ask again with a GET".
        let headRejected = response.map { [400, 403, 405, 501].contains($0.statusCode) } ?? true
        if headRejected {
            var ranged = URLRequest(url: url)
            ranged.httpMethod = "GET"
            ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            ranged.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            ranged.timeoutInterval = 30
            do {
                let (_, raw) = try await session.data(for: ranged)
                response = raw as? HTTPURLResponse
            } catch let error as URLError {
                throw TransferError.network(error.localizedDescription)
            } catch {
                throw TransferError.network(error.localizedDescription)
            }
        }

        guard let http = response else { throw TransferError.network("The server did not answer.") }
        if http.statusCode == 404 || http.statusCode == 410 { throw TransferError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw TransferError.network("The server answered HTTP \(http.statusCode).")
        }

        let headers = Self.headerLookup(http)
        let totalBytes = Self.totalBytes(from: http, headers: headers)
        let acceptsRanges = (headers["accept-ranges"] ?? "").lowercased().contains("bytes")
        let supportsResume = (acceptsRanges || http.statusCode == 206) && (totalBytes ?? 0) > 0

        let mimeType = (headers["content-type"] ?? http.mimeType ?? "")
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        let validator = headers["etag"] ?? headers["last-modified"]
        let filename = Self.filename(from: headers["content-disposition"], url: url)
        let category = ProbeResult.category(mimeType: mimeType, filename: filename)

        return ProbeResult(
            filename: filename,
            totalBytes: totalBytes,
            supportsResume: supportsResume,
            mimeType: mimeType,
            isStreamable: supportsResume && category == "Video",
            validator: validator
        )
    }

    static func headerLookup(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            out[key.lowercased()] = value
        }
        return out
    }

    /// `Content-Length` normally; the total from `Content-Range: bytes 0-0/12345` when the probe
    /// had to fall back to a one-byte GET, because `Content-Length` is `1` in that case.
    static func totalBytes(from response: HTTPURLResponse, headers: [String: String]) -> Int64? {
        if let contentRange = headers["content-range"],
           let slash = contentRange.lastIndex(of: "/") {
            let tail = contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if tail != "*", let value = Int64(tail), value > 0 { return value }
        }
        if let raw = headers["content-length"], let value = Int64(raw), value >= 0 {
            return response.statusCode == 206 ? nil : value
        }
        let expected = response.expectedContentLength
        return expected >= 0 ? expected : nil
    }

    /// `Content-Disposition` wins, then the URL's last path component, then `"download"`.
    /// Percent-decoded and stripped of any path, because a server is perfectly capable of
    /// sending `filename="../../Library/Preferences/com.apple.plist"`.
    static func filename(from contentDisposition: String?, url: URL) -> String {
        if let disposition = contentDisposition {
            // RFC 5987 `filename*=UTF-8''name.bin` is preferred: it carries an encoding.
            if let range = disposition.range(of: "filename*=", options: .caseInsensitive) {
                var value = String(disposition[range.upperBound...])
                if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
                if let tick = value.range(of: "''") { value = String(value[tick.upperBound...]) }
                let cleaned = FileStore.sanitizedFilename(value.trimmingCharacters(in: .whitespaces))
                if cleaned != "download" { return cleaned }
            }
            if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                var value = String(disposition[range.upperBound...])
                if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                let cleaned = FileStore.sanitizedFilename(value)
                if cleaned != "download" { return cleaned }
            }
        }
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return "download" }
        return FileStore.sanitizedFilename(last)
    }

    // MARK: - Start

    public func start(_ download: Download) async throws {
        guard let scheme = download.url.scheme?.lowercased(), !scheme.isEmpty else {
            throw TransferError.invalidURL
        }
        guard Self.supportedSchemes.contains(scheme) else {
            throw TransferError.unsupportedScheme(scheme)
        }

        teardown(download.id)

        continuation.yield(.statusChanged(id: download.id, status: .probing))
        let probed = try await probe(download.url)

        var updated = download
        updated.totalBytes = probed.totalBytes
        updated.supportsResume = probed.supportsResume
        updated.validator = probed.validator
        if updated.filename.trimmingCharacters(in: .whitespaces).isEmpty {
            updated.filename = probed.filename
        }
        updated.errorMessage = nil
        updated.status = .downloading

        let destination: URL
        do {
            destination = try store.destinationURL(
                filename: updated.filename,
                subdirectory: updated.saveDirectory
            )
        } catch let error as FileStoreError {
            throw error.asTransferError
        }

        var job = Job(
            download: updated,
            destination: destination,
            part: store.partURL(for: destination),
            checkpoint: store.checkpointURL(for: destination),
            lastEmit: .now,
            lastCheckpoint: .now
        )

        // Adopt a checkpoint only when it provably describes the same remote file. Anything
        // ambiguous is discarded with its bytes rather than spliced into a different file.
        if let checkpoint = store.loadCheckpoint(at: job.checkpoint),
           checkpoint.matches(url: updated.url, validator: updated.validator),
           checkpoint.totalBytes == updated.totalBytes {
            job.completed = HandoffState.merged(checkpoint.completedRanges)
        } else {
            store.removeCheckpoint(at: job.checkpoint)
            store.removePart(at: job.part)
        }

        job.connections = SegmentPlan.connectionCount(
            tuning: tuning,
            totalBytes: updated.totalBytes,
            supportsResume: updated.supportsResume
        )

        do {
            job.file = try store.openPart(at: job.part, size: updated.totalBytes)
        } catch let error as FileStoreError {
            throw error.asTransferError
        }

        let gaps: [ClosedRange<Int64>]
        if let total = updated.totalBytes, total > 0 {
            gaps = HandoffState.gaps(in: job.completed, total: total)
        } else {
            // No length: one stream from wherever we are, open-ended. `Int64.max` as the upper
            // bound is never sent in a header — an unknown-length transfer sends no `Range` at all.
            gaps = [0...Int64.max - 1]
        }
        job.pending = SegmentPlan
            .plan(gaps: gaps, connections: job.connections, isSequential: updated.isSequential)
            .map { PendingRange(range: $0) }

        jobs[download.id] = job
        store.saveManifest(
            BackgroundHandoffManifest(
                downloadID: download.id,
                url: updated.url.absoluteString,
                partPath: job.part.path,
                destinationPath: destination.path,
                offset: 0,
                totalBytes: updated.totalBytes,
                validator: updated.validator
            )
        )
        writeCheckpoint(download.id)

        if let blocked = Self.policyStatus(isCellular: isCellular, isExpensive: isExpensive, tuning: tuning) {
            park(download.id, status: blocked)
            return
        }

        // The UI is told up front, not at 99 %: PRD §4.1.
        continuation.yield(.statusChanged(id: download.id, status: .downloading))
        emitProgress(download.id, force: true)
        launch(download.id)
    }

    // MARK: - Pause / resume / cancel

    public func pause(_ id: UUID) async {
        guard var job = jobs[id] else {
            // Nothing to pause. Say so rather than leaving the UI showing a spinner forever.
            continuation.yield(.statusChanged(id: id, status: .paused))
            return
        }
        let runner = job.runner
        job.runner = nil
        job.isPaused = true
        job.download.status = .paused
        jobs[id] = job
        runner?.cancel()
        coordinator?.cancelBackgroundTransfer(id)
        writeCheckpoint(id)
        continuation.yield(.statusChanged(id: id, status: .paused))
    }

    public func resume(_ id: UUID) async {
        guard jobs[id] != nil else {
            // A cold launch loses the in-memory job. The manifest written at `start` is what
            // makes a resume after relaunch possible at all.
            await resumeFromManifest(id)
            return
        }
        if let blocked = Self.policyStatus(isCellular: isCellular, isExpensive: isExpensive, tuning: tuning) {
            park(id, status: blocked)
            return
        }
        guard var job = jobs[id] else { return }
        job.isPaused = false
        job.failure = nil
        job.download.status = .downloading
        job.download.errorMessage = nil
        job.lastEmit = .now
        job.lastCheckpoint = .now
        // Re-plan from what is actually on disk, so a connection-count change lands here.
        job.connections = SegmentPlan.connectionCount(
            tuning: tuning,
            totalBytes: job.download.totalBytes,
            supportsResume: job.download.supportsResume
        )
        if let total = job.download.totalBytes, total > 0 {
            var covered = job.completed
            for claim in job.active.values where claim.received > 0 {
                covered.append(claim.range.lowerBound...(claim.range.lowerBound + claim.received - 1))
            }
            job.completed = HandoffState.merged(covered)
            job.active = [:]
            job.pending = SegmentPlan
                .plan(
                    gaps: HandoffState.gaps(in: job.completed, total: total),
                    connections: job.connections,
                    isSequential: job.download.isSequential
                )
                .map { PendingRange(range: $0) }
        }
        if job.file == nil {
            job.file = try? store.openPart(at: job.part, size: job.download.totalBytes)
        }
        jobs[id] = job
        guard job.file != nil else {
            failJob(id, error: .network("Could not reopen the partial file."))
            return
        }
        continuation.yield(.statusChanged(id: id, status: .downloading))
        launch(id)
    }

    /// Rebuilds a job after an app relaunch from the manifest + checkpoint on disk, then resumes.
    private func resumeFromManifest(_ id: UUID) async {
        guard let manifest = store.loadManifest(for: id),
              let url = URL(string: manifest.url) else {
            continuation.yield(.statusChanged(id: id, status: .paused))
            return
        }
        let destination = URL(filePath: manifest.destinationPath)
        guard FileStore.isContained(destination, in: store.root) else {
            continuation.yield(.failed(id: id, message: TransferError.invalidURL.userMessage))
            return
        }
        var download = Download(
            id: id,
            url: url,
            filename: destination.lastPathComponent,
            saveDirectory: destination.deletingLastPathComponent().path,
            kind: Download.Kind.infer(from: url),
            status: .downloading,
            totalBytes: manifest.totalBytes,
            supportsResume: true,
            validator: manifest.validator
        )
        if let checkpoint = store.loadCheckpoint(at: store.checkpointURL(for: destination)) {
            download.isSequential = checkpoint.isSequential
            download.supportsResume = checkpoint.supportsResume
        }
        do {
            try await start(download)
        } catch {
            continuation.yield(.failed(id: id, message: asTransferError(error).userMessage))
        }
    }

    public func cancel(_ id: UUID, deleteData: Bool) async {
        coordinator?.cancelBackgroundTransfer(id)
        guard var job = jobs[id] else {
            if deleteData { store.removeManifest(for: id) }
            return
        }
        let runner = job.runner
        job.runner = nil
        job.isCancelled = true
        jobs[id] = job
        runner?.cancel()
        if deleteData {
            store.removePart(at: job.part)
            store.removeCheckpoint(at: job.checkpoint)
            store.removeManifest(for: id)
        } else {
            writeCheckpoint(id)
        }
        jobs[id] = nil
        verifiedChecksums[id] = nil
    }

    private func teardown(_ id: UUID) {
        guard let job = jobs[id] else { return }
        job.runner?.cancel()
        jobs[id] = nil
    }

    // MARK: - The worker pool

    private func launch(_ id: UUID) {
        guard var job = jobs[id], job.failure == nil, !job.isPaused, !job.isCancelled else { return }
        let workers = max(1, min(job.connections, job.pending.count + job.active.count))
        job.runner = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<workers {
                    group.addTask { await self.workerLoop(id, worker: worker) }
                }
            }
            await self.finishJob(id)
        }
        jobs[id] = job
    }

    private func workerLoop(_ id: UUID, worker: Int) async {
        while !Task.isCancelled {
            guard let claimID = claimNext(id) else { return }
            switch await runClaim(id, claimID: claimID) {
            case .done: continue
            case .stop: return
            }
        }
    }

    /// Claims the **lowest** unclaimed range.
    ///
    /// In parallel mode this is just tidy. In sequential mode it is the correctness rule: because
    /// every worker always takes the lowest remaining block, the set of in-flight blocks is always
    /// the run immediately after the completed prefix, and no connection can ever open ahead of a
    /// gap. That is what keeps bytes `0…n` contiguous and the file playable while it downloads.
    private func claimNext(_ id: UUID) -> Int? {
        guard var job = jobs[id], !job.isPaused, !job.isCancelled, job.failure == nil else { return nil }
        guard let index = job.pending.indices.min(by: {
            job.pending[$0].range.lowerBound < job.pending[$1].range.lowerBound
        }) else { return nil }

        let pending = job.pending.remove(at: index)
        let claimID = job.nextClaimID
        job.nextClaimID += 1
        job.active[claimID] = ActiveClaim(
            range: pending.range,
            received: 0,
            attempts: pending.attempts,
            handedOff: pending.handedOff
        )
        jobs[id] = job
        return claimID
    }

    private func runClaim(_ id: UUID, claimID: Int) async -> ClaimOutcome {
        while true {
            if Task.isCancelled {
                parkClaim(id, claimID: claimID, handedOff: false)
                return .stop
            }
            do {
                try await fetchClaim(id, claimID: claimID)
                completeClaim(id, claimID: claimID)
                return .done
            } catch is CancellationError {
                parkClaim(id, claimID: claimID, handedOff: false)
                return .stop
            } catch let error as TransferError where error == .remoteFileChanged {
                parkClaim(id, claimID: claimID, handedOff: false)
                failJob(id, error: .remoteFileChanged)
                return .stop
            } catch {
                switch nextAttempt(id, claimID: claimID) {
                case let .retry(delay):
                    log.warning("segment \(claimID) retrying in \(delay, format: .fixed(precision: 2))s: \(error.localizedDescription, privacy: .public)")
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        parkClaim(id, claimID: claimID, handedOff: false)
                        return .stop
                    }
                case .handOff:
                    // Already returned to the pool with its written prefix banked; another
                    // connection picks it up. Go take whatever is lowest now.
                    return .done
                case .fail:
                    parkClaim(id, claimID: claimID, handedOff: true)
                    failJob(id, error: asTransferError(error))
                    return .stop
                }
            }
        }
    }

    private func nextAttempt(_ id: UUID, claimID: Int) -> Attempt {
        guard var job = jobs[id], var claim = job.active[claimID] else { return .fail }
        claim.attempts += 1
        if claim.attempts <= Self.maxAttemptsPerRange {
            job.active[claimID] = claim
            jobs[id] = job
            return .retry(SegmentPlan.backoffDelay(attempt: claim.attempts, seed: claimID))
        }
        // Three attempts spent. If this range has never been handed over, hand it over: a second
        // connection on a different socket often succeeds where the first kept failing.
        guard !claim.handedOff else { return .fail }
        job.active[claimID] = claim
        jobs[id] = job
        parkClaim(id, claimID: claimID, handedOff: true)
        return .handOff
    }

    // MARK: - Fetching one claim

    private func fetchClaim(_ id: UUID, claimID: Int) async throws {
        guard let job = jobs[id], let claim = job.active[claimID], let file = job.file else { return }
        let download = job.download
        let start = claim.range.lowerBound + claim.received
        guard start <= claim.range.upperBound else { return }

        var request = URLRequest(url: download.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        // No transparent compression: a gzipped body's byte offsets are not the file's byte
        // offsets, and every offset in this engine is a file offset.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let hasKnownEnd = claim.range.upperBound < Int64.max - 1
        let usesRange = download.supportsResume && hasKnownEnd
        if usesRange {
            request.setValue(
                HandoffState.rangeHeaderValue(start...claim.range.upperBound),
                forHTTPHeaderField: "Range"
            )
            if let validator = download.validator {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        let coversWholeFile = start == 0
            && (download.totalBytes.map { claim.range.upperBound == $0 - 1 } ?? true)

        let chunkSize = max(16 * 1024, tuning.trafficProfile.chunkSize)
        let feed = HTTPChunkFeed(
            session: session,
            request: request,
            highWater: max(chunkSize * 4, 1 << 20)
        )
        defer { feed.cancel() }

        var cursor = start
        let end = claim.range.upperBound
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var unacknowledged = 0
        var sawResponse = false
        var isSatisfied = false

        for try await element in feed.stream {
            try Task.checkCancellation()
            switch element {
            case let .response(http):
                sawResponse = true
                try Self.validate(http, usesRange: usesRange, coversWholeFile: coversWholeFile)

            case let .chunk(data):
                let room = end - (cursor + Int64(buffer.count)) + 1
                if room <= 0 {
                    isSatisfied = true
                } else {
                    let slice = Int64(data.count) > room ? data.prefix(Int(room)) : data
                    buffer.append(slice)
                    unacknowledged += slice.count
                    if buffer.count >= chunkSize {
                        try await flush(id: id, claimID: claimID, file: file, buffer: &buffer, cursor: &cursor)
                        feed.consumed(unacknowledged)
                        unacknowledged = 0
                    }
                }
            }
            if isSatisfied { break }
        }

        if !buffer.isEmpty {
            try await flush(id: id, claimID: claimID, file: file, buffer: &buffer, cursor: &cursor)
            feed.consumed(unacknowledged)
        }

        guard sawResponse else {
            throw TransferError.network("The server closed the connection before answering.")
        }
        guard isSatisfied || !hasKnownEnd || cursor > end else {
            // The socket ended mid-range. Throwing puts this claim through the retry path, which
            // resumes from the cursor rather than from the start of the range.
            throw TransferError.network("The connection ended early.")
        }
    }

    /// The status-code rules. Every one of these is a case where continuing would produce a file
    /// that is the right length and the wrong contents.
    static func validate(_ http: HTTPURLResponse, usesRange: Bool, coversWholeFile: Bool) throws {
        switch http.statusCode {
        case 206:
            return
        case 200:
            // We asked for a range and got the whole file: either the server ignores `Range`, or
            // `If-Range` did not match and RFC 9110 §13.1.5 told it to send a full 200. Both mean
            // the bytes we already hold cannot be trusted against this body.
            guard !usesRange || coversWholeFile else { throw TransferError.remoteFileChanged }
        case 416:
            // The range we asked for no longer exists: the file got shorter.
            throw TransferError.remoteFileChanged
        case 404, 410:
            throw TransferError.notFound
        case 401, 403:
            throw TransferError.network("The server refused the request (HTTP \(http.statusCode)).")
        default:
            guard (200..<300).contains(http.statusCode) else {
                throw TransferError.network("The server answered HTTP \(http.statusCode).")
            }
        }
    }

    private func flush(
        id: UUID,
        claimID: Int,
        file: SparseFile,
        buffer: inout Data,
        cursor: inout Int64
    ) async throws {
        guard !buffer.isEmpty else { return }
        let payload = buffer
        buffer.removeAll(keepingCapacity: true)

        let wait = await bucket.reserve(payload.count)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()

        do {
            try file.write(payload, at: cursor)
        } catch let error as FileStoreError {
            throw error.asTransferError
        }
        cursor += Int64(payload.count)
        record(id: id, claimID: claimID, bytes: Int64(payload.count))
    }

    // MARK: - Bookkeeping

    private func record(id: UUID, claimID: Int, bytes: Int64) {
        guard var job = jobs[id] else { return }
        if var claim = job.active[claimID] {
            claim.received = min(claim.received + bytes, SegmentPlan.length(of: claim.range))
            job.active[claimID] = claim
        }
        job.bytesSinceEmit += bytes
        job.download.receivedBytes = Self.totalReceived(job.completed, job.active)
        jobs[id] = job

        let now = ContinuousClock.now
        if job.lastEmit.duration(to: now) >= Self.progressInterval {
            emitProgress(id, force: true)
        }
        if job.lastCheckpoint.duration(to: now) >= Self.checkpointInterval {
            writeCheckpoint(id)
        }
    }

    private static func totalReceived(
        _ completed: [ClosedRange<Int64>],
        _ active: [Int: ActiveClaim]
    ) -> Int64 {
        completed.reduce(Int64(0)) { $0 + SegmentPlan.length(of: $1) }
            + active.values.reduce(Int64(0)) { $0 + $1.received }
    }

    /// The `[Download.Segment]` the UI draws, rebuilt from the job's three range collections.
    ///
    /// Completed ranges are merged, so a sequential download's hundred finished blocks collapse
    /// into one long green bar rather than a hundred slivers, and `Download.contiguousPrefix` can
    /// walk the result correctly.
    private func segmentsSnapshot(_ job: Job) -> [Download.Segment] {
        var out: [Download.Segment] = []
        for range in job.completed {
            out.append(
                Download.Segment(
                    id: 0,
                    range: range,
                    receivedBytes: SegmentPlan.length(of: range),
                    isActive: false
                )
            )
        }
        for claim in job.active.values {
            out.append(
                Download.Segment(id: 0, range: claim.range, receivedBytes: claim.received, isActive: true)
            )
        }
        for range in HandoffState.merged(job.pending.map(\.range)) where range.upperBound < Int64.max - 1 {
            out.append(Download.Segment(id: 0, range: range, receivedBytes: 0, isActive: false))
        }
        out.sort { $0.range.lowerBound < $1.range.lowerBound }
        return out.enumerated().map { index, segment in
            var segment = segment
            segment.id = index
            return segment
        }
    }

    private func emitProgress(_ id: UUID, force: Bool) {
        guard var job = jobs[id] else { return }
        let now = ContinuousClock.now
        guard force || job.lastEmit.duration(to: now) >= Self.progressInterval else { return }

        let elapsed = Self.seconds(job.lastEmit.duration(to: now))
        let speed = elapsed > 0 ? Double(job.bytesSinceEmit) / elapsed : 0
        let segments = segmentsSnapshot(job)

        // The engine is the only thing that knows a byte crossed a cellular interface, so it is
        // the only thing that can feed Settings' "Data used this month".
        if isCellular || isExpensive { noteCellularBytes(job.bytesSinceEmit) }

        job.lastEmit = now
        job.bytesSinceEmit = 0
        job.download.segments = segments
        job.download.receivedBytes = Self.totalReceived(job.completed, job.active)
        jobs[id] = job

        continuation.yield(
            .progress(
                id: id,
                received: job.download.receivedBytes,
                total: job.download.totalBytes,
                speed: speed.isFinite ? max(0, speed) : 0,
                segments: segments
            )
        )
    }

    /// Accumulates cellular bytes and writes them through in batches.
    ///
    /// `emitProgress` runs at 10 Hz per transfer; a `UserDefaults` write per tick would be a few
    /// hundred writes a minute for a number nobody reads more than once a month. Flush on 8 MB or
    /// ten seconds, whichever comes first, and on the way to the background.
    private func noteCellularBytes(_ bytes: Int64) {
        guard bytes > 0 else { return }
        cellularBytesPending += bytes
        let now = ContinuousClock.now
        guard cellularBytesPending >= Self.cellularFlushBytes
                || lastCellularFlush.duration(to: now) >= Self.cellularFlushInterval
        else { return }
        flushCellularLedger()
    }

    private func flushCellularLedger() {
        guard cellularBytesPending > 0 else { return }
        _ = CellularDataLedger.record(cellularBytesPending)
        cellularBytesPending = 0
        lastCellularFlush = ContinuousClock.now
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func writeCheckpoint(_ id: UUID) {
        guard var job = jobs[id] else { return }
        // Bank each in-flight claim's written prefix too — those bytes are on disk whether or not
        // the claim ever finishes, and re-downloading them after a kill is pure waste.
        var covered = job.completed
        for claim in job.active.values where claim.received > 0 {
            covered.append(claim.range.lowerBound...(claim.range.lowerBound + claim.received - 1))
        }
        job.lastCheckpoint = .now
        jobs[id] = job

        store.saveCheckpoint(
            TransferCheckpoint(
                url: job.download.url.absoluteString,
                totalBytes: job.download.totalBytes,
                validator: job.download.validator,
                supportsResume: job.download.supportsResume,
                isSequential: job.download.isSequential,
                completed: HandoffState.merged(covered)
            ),
            at: job.checkpoint
        )
    }

    private func completeClaim(_ id: UUID, claimID: Int) {
        guard var job = jobs[id], let claim = job.active.removeValue(forKey: claimID) else { return }
        job.completed = HandoffState.merged(job.completed + [claim.range])
        jobs[id] = job
        writeCheckpoint(id)
        emitProgress(id, force: true)
    }

    /// Returns a claim to the pool, banking whatever it managed to write.
    private func parkClaim(_ id: UUID, claimID: Int, handedOff: Bool) {
        guard var job = jobs[id], let claim = job.active.removeValue(forKey: claimID) else { return }
        let lower = claim.range.lowerBound
        if claim.received > 0 {
            job.completed = HandoffState.merged(job.completed + [lower...(lower + claim.received - 1)])
        }
        let next = lower + claim.received
        if next <= claim.range.upperBound {
            job.pending.append(
                PendingRange(
                    range: next...claim.range.upperBound,
                    attempts: handedOff ? 0 : claim.attempts,
                    handedOff: handedOff || claim.handedOff
                )
            )
        }
        jobs[id] = job
        writeCheckpoint(id)
    }

    private func failJob(_ id: UUID, error: TransferError) {
        guard var job = jobs[id], job.failure == nil else { return }
        job.failure = error
        let runner = job.runner
        job.runner = nil
        jobs[id] = job
        runner?.cancel()
        coordinator?.cancelBackgroundTransfer(id)

        if error == .remoteFileChanged {
            // The bytes on disk belong to a different file. Keeping them guarantees a corrupt
            // splice on the next attempt, so they go — loudly, with a message that tells the user
            // to start it again for the new version.
            store.removePart(at: job.part)
            store.removeCheckpoint(at: job.checkpoint)
            store.removeManifest(for: id)
            jobs[id] = nil
        } else {
            writeCheckpoint(id)
        }
        log.error("download \(id, privacy: .public) failed: \(error.userMessage, privacy: .public)")
        continuation.yield(.failed(id: id, message: error.userMessage))
    }

    private func asTransferError(_ error: any Error) -> TransferError {
        if let error = error as? TransferError { return error }
        if let error = error as? FileStoreError { return error.asTransferError }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .fileDoesNotExist, .badURL, .unsupportedURL: return .notFound
            default: return .network(error.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    // MARK: - Completion

    private func finishJob(_ id: UUID) async {
        guard let job = jobs[id], !job.isCancelled, job.failure == nil, !job.isPaused else { return }
        guard job.pending.isEmpty, job.active.isEmpty else { return }

        let received = Self.totalReceived(job.completed, job.active)
        if let total = job.download.totalBytes, received < total {
            failJob(id, error: .network("The download stopped \(total - received) bytes short."))
            return
        }
        job.file?.synchronize()

        var verified = false
        if tuning.verifyChecksums, let expected = await checksumSidecar(for: job.download.url) {
            continuation.yield(.statusChanged(id: id, status: .verifying))
            let part = job.part
            let digest: String?
            do {
                digest = try await Task.detached(priority: .utility) {
                    try FileStore.sha256Hex(ofFileAt: part)
                }.value
            } catch {
                // Hashing failed (the file vanished, or the read errored). That is not proof the
                // download is bad, so the file is kept — but verification is not claimed either.
                log.error("checksum read failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                digest = nil
            }
            if let digest {
                guard digest == expected else {
                    store.removePart(at: part)
                    store.removeCheckpoint(at: job.checkpoint)
                    store.removeManifest(for: id)
                    jobs[id] = nil
                    verifiedChecksums[id] = false
                    continuation.yield(.failed(id: id, message: TransferError.checksumMismatch.userMessage))
                    return
                }
                verified = true
            }
        }

        do {
            let finalURL = try store.finalize(part: job.part, to: job.destination)
            store.removeCheckpoint(at: job.checkpoint)
            store.removeManifest(for: id)
            jobs[id] = nil
            verifiedChecksums[id] = verified
            continuation.yield(
                .progress(
                    id: id,
                    received: received,
                    total: job.download.totalBytes ?? received,
                    speed: 0,
                    segments: [
                        Download.Segment(
                            id: 0,
                            range: 0...max(0, received - 1),
                            receivedBytes: received,
                            isActive: false
                        )
                    ]
                )
            )
            continuation.yield(.completed(id: id, fileURL: finalURL))
        } catch let error as FileStoreError {
            failJob(id, error: error.asTransferError)
        } catch {
            failJob(id, error: .network(error.localizedDescription))
        }
    }

    /// The digest from `<url>.sha256`, or `nil` when there is no sidecar. `nil` is not a failure —
    /// it means we cannot claim verification, and ``checksumVerified(_:)`` stays `false`.
    private func checksumSidecar(for url: URL) async -> String? {
        guard let sidecar = URL(string: url.absoluteString + ".sha256") else { return nil }
        var request = URLRequest(url: sidecar)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { return nil }
            return FileStore.parseChecksumSidecar(text)
        } catch {
            log.debug("no checksum sidecar for \(url.absoluteString, privacy: .public)")
            return nil
        }
    }

    // MARK: - T06 handoff

    /// `.active → .background`: checkpoint, cancel the segments, and re-issue the remainder as
    /// **one** background `URLSession` task anchored on the contiguous prefix.
    public func enterBackground() async {
        // Nothing else will run before suspension; an unflushed counter would be lost.
        flushCellularLedger()
        guard let coordinator else { return }
        for (id, job) in jobs {
            var snapshot = job.download
            snapshot.segments = segmentsSnapshot(job)
            snapshot.receivedBytes = Self.totalReceived(job.completed, job.active)

            guard HandoffState.strategy(for: .background, download: snapshot) == .backgroundSingle,
                  let range = HandoffState.rangeForResume(snapshot)
            else { continue }

            // Order matters: stop the segmenters first, then checkpoint, then hand over. The
            // prefix may be a few bytes stale by the time the workers actually unwind, which
            // costs a re-download of those bytes and never a hole.
            let runner = job.runner
            jobs[id]?.runner = nil
            runner?.cancel()
            writeCheckpoint(id)

            jobs[id]?.handedToBackground = true
            coordinator.beginBackgroundTransfer(
                downloadID: id,
                url: snapshot.url,
                range: range,
                validator: snapshot.validator,
                totalBytes: snapshot.totalBytes,
                part: job.part,
                destination: job.destination,
                checkpoint: job.checkpoint
            )
            log.info("handed \(id, privacy: .public) to the background session from byte \(range.lowerBound)")
        }
    }

    /// `.background → .active`: take back whatever the background task wrote, re-probe the
    /// validator, and re-segment the remainder — or fail loudly if the file changed underneath us.
    public func enterForeground() async {
        guard let coordinator else { return }
        for (id, job) in jobs where job.handedToBackground {
            coordinator.cancelBackgroundTransfer(id)
            jobs[id]?.handedToBackground = false
            await adoptFromDisk(id)
        }
    }

    /// Re-reads the checkpoint (which the coordinator extends on the background task's behalf,
    /// possibly in a different process launch), re-validates, and restarts segmentation.
    private func adoptFromDisk(_ id: UUID) async {
        guard var job = jobs[id] else { return }
        let fresh: ProbeResult?
        do {
            fresh = try await probe(job.download.url)
        } catch {
            // A failed re-probe is not evidence the file changed — it is evidence the network is
            // down. Keep the bytes, keep the job, and let the ordinary retry path deal with it.
            log.warning("re-probe failed for \(id, privacy: .public); keeping bytes and retrying")
            fresh = nil
        }

        if let fresh {
            guard HandoffState.canAdoptBackgroundResult(job.download, validator: fresh.validator) else {
                failJob(id, error: .remoteFileChanged)
                return
            }
            job.download.validator = fresh.validator
            job.download.totalBytes = fresh.totalBytes ?? job.download.totalBytes
            job.download.supportsResume = fresh.supportsResume
        }

        if let checkpoint = store.loadCheckpoint(at: job.checkpoint),
           checkpoint.matches(url: job.download.url, validator: job.download.validator) {
            job.completed = HandoffState.merged(job.completed + checkpoint.completedRanges)
        }
        job.active = [:]
        job.isPaused = false
        jobs[id] = job
        await resume(id)
    }

    private func handleBackgroundEvent(_ event: BackgroundEvent) async {
        switch event {
        case let .progress(id, contiguousBytes):
            guard var job = jobs[id] else { return }
            guard let total = job.download.totalBytes, contiguousBytes > 0 else { return }
            job.completed = HandoffState.merged(job.completed + [0...min(contiguousBytes, total) - 1])
            jobs[id] = job
            emitProgress(id, force: true)

        case let .finished(id, contiguousBytes):
            guard var job = jobs[id] else { return }
            job.handedToBackground = false
            let total = job.download.totalBytes ?? contiguousBytes
            job.completed = HandoffState.merged(job.completed + [0...max(0, min(contiguousBytes, total) - 1)])
            job.pending = []
            job.active = [:]
            jobs[id] = job
            await finishJob(id)

        case let .failed(id, error):
            guard jobs[id] != nil else { return }
            jobs[id]?.handedToBackground = false
            if error == .remoteFileChanged {
                failJob(id, error: .remoteFileChanged)
            } else {
                // The background session retries on its own; a reported failure here means it gave
                // up. Park rather than destroy — the bytes are still good.
                park(id, status: .paused)
            }
        }
    }
}
