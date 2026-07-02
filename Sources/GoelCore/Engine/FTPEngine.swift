import Foundation
import CurlBridge

/// FTP/FTPS downloads via the system libcurl (through the ``CurlBridge`` C
/// shim — `curl_easy_setopt` is variadic and unreachable from Swift).
///
/// One blocking libcurl transfer per task, each on its own dedicated thread
/// (never the cooperative pool — a transfer can block for hours). Resume is
/// byte-offset based: the engine restarts from the partial file's on-disk
/// size using FTP `REST`, so no resume cursor is needed. `ftps://` is
/// implicit TLS; plain `ftp://` opportunistically upgrades via `AUTH TLS`
/// when the server supports it.
public actor FTPEngine: DownloadEngine {

    public nonisolated let kind: DownloadKind = .ftp
    public nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata] }

    private nonisolated let hub = EventHub()
    /// Username/password lookup for hosts the user stored logins for.
    private nonisolated let credentialLookup: @Sendable (String) -> (username: String, password: String)?

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    /// Live transfer contexts, so pause/remove can abort the blocking perform.
    private var contexts: [UUID: FTPTransferContext] = [:]
    private var profile: TrafficProfile

    public init(profile: TrafficProfile,
                credentialLookup: (@Sendable (String) -> (username: String, password: String)?)? = nil) {
        self.profile = profile
        if let credentialLookup {
            self.credentialLookup = credentialLookup
        } else {
            let store = KeychainCredentialStore()
            self.credentialLookup = { host in store.credential(forHost: host) }
        }
    }

    // MARK: DownloadEngine

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .ftp }

    public func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    public func pause(_ id: UUID) async {
        contexts[id]?.abort()
        // Cancel a queued-but-not-started job; a mid-flight curl transfer
        // stops via the abort flag. `jobs[id]` is kept so the next start
        // serializes on the old transfer actually finishing.
        jobs[id]?.cancel()
    }

    public func resume(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        startJob(id)
    }

    public func remove(_ id: UUID, deleteData: Bool) async {
        contexts[id]?.abort()
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        let task = tasks[id]
        tasks[id] = nil
        // The curl thread keeps writing until it notices the abort — wait for
        // it before touching the file, or a re-added download at the same
        // path could receive the old transfer's bytes.
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    public func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    public nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    /// Preview probe: a body-less transfer reporting the remote size.
    public func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source, source.kind == .ftp else { return nil }
        let name = PathSafety.sanitizedName(url.lastPathComponent, fallback: url.host ?? "download")
        let credential = credentials(for: url)
        let probe = await Self.remoteSizeBlocking(url: url.absoluteString,
                                                  userpwd: credential?.userpwd,
                                                  requireTLS: credential?.requireTLS ?? false)
        // A reachable server that simply doesn't advertise a size (size == -1) is
        // still reachable — don't mislabel it "couldn't reach the server".
        return EngineMetadata(name: name, totalBytes: probe.size >= 0 ? probe.size : nil,
                              reachable: probe.reachable)
    }

    // MARK: Transfer

    private func startJob(_ id: UUID) {
        // Never overlap two transfers for one task: the previous curl thread
        // may keep writing briefly after an abort, so the new job first waits
        // for the old one to fully finish (two writers on one file corrupt it).
        contexts[id]?.abort()
        let previous = jobs[id]
        previous?.cancel()
        let profile = self.profile
        jobs[id] = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await self.run(id, profile: profile)
        }
    }

    private func run(_ id: UUID, profile: TrafficProfile) async {
        guard let task = tasks[id], case .url(let url) = task.source else {
            let e = DownloadError.unknown("FTPEngine requires an ftp:// source")
            hub.fail(id, e)
            return
        }
        guard task.isSavePathContained else {
            let e = DownloadError.unknown("Path traversal blocked")
            hub.fail(id, e)
            return
        }
        emit(id, .statusChanged(.downloading))

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: task.saveDirectory, withIntermediateDirectories: true)
        } catch {
            let e = DownloadError.unknown("Couldn’t create the download folder")
            hub.fail(id, e)
            return
        }

        let fileURL = URL(fileURLWithPath: task.savePath)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
        let resumeFrom = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            let e = DownloadError.fileMissing
            hub.fail(id, e)
            return
        }
        _ = try? handle.seekToEnd()

        // Effective cap: the tighter of the profile ceiling and the task cap.
        let cap = profile.effectiveDownloadCap(taskLimit: task.speedLimitBytesPerSec)

        let context = FTPTransferContext(hub: hub, id: id, name: task.name,
                                         handle: handle, resumeFrom: resumeFrom)
        contexts[id] = context
        defer { contexts[id] = nil }

        let credential = credentials(for: url)
        let result = await Self.downloadBlocking(
            url: url.absoluteString, resumeFrom: resumeFrom,
            userpwd: credential?.userpwd,
            requireTLS: credential?.requireTLS ?? false,
            maxBytesPerSecond: cap, context: context)
        try? handle.close()

        if gcb_is_aborted(result.code) != 0 {
            return   // our own pause/remove; the manager owns the state
        }
        // NOTE: run() never touches jobs[id] — startJob() may already have
        // stored a successor job's handle, and nilling it here would break
        // the serialization remove()/startJob() rely on.
        guard result.code == 0 else {
            let message = String(cString: gcb_error_message(result.code))
            let e = DownloadError.network(message)
            hub.fail(id, e)
            return
        }

        // Success: report the final byte count, verify if asked, complete.
        let written = resumeFrom + context.bytesWritten
        emit(id, .metadataResolved(name: task.name, totalBytes: written,
                                   files: [TransferFile(id: 0, path: task.name, length: written)]))
        emit(id, .progress(bytesDownloaded: written, bytesUploaded: 0,
                           downloadSpeed: 0, uploadSpeed: 0, connectionCount: 0))
        if let expected = task.expectedChecksum {
            emit(id, .statusChanged(.verifying))
            let matches = (try? await ChecksumVerifier.verify(fileAt: fileURL, expected: expected)) ?? false
            guard matches else {
                let e = DownloadError.checksumMismatch
                hub.fail(id, e)
                return
            }
        }
        emit(id, .finished)
        emit(id, .statusChanged(.completed))
    }

    /// The login for a URL, plus whether TLS must be REQUIRED to send it.
    /// Inline `ftp://user:pass@host` userinfo is the user's own explicit
    /// choice for that URL (opportunistic TLS, like any FTP client). Keychain
    /// site logins were stored under an "encrypted transport only" promise
    /// (the HTTP engine sends them over HTTPS exclusively), so here they ride
    /// only a TLS-protected session — the transfer fails rather than let a
    /// downgraded server read the password off the wire.
    private func credentials(for url: URL) -> (userpwd: String, requireTLS: Bool)? {
        // Only treat inline userinfo as complete credentials when a password is
        // actually present. A bare `ftp://user@host` (e.g. after inline-password
        // stripping in `DownloadSource.parse`) must fall through to the Keychain
        // rather than authenticate with an empty password and skip the lookup.
        if let user = url.user, !user.isEmpty, let pass = url.password, !pass.isEmpty {
            return ("\(user):\(pass)", false)
        }
        if let host = url.host, let stored = credentialLookup(host) {
            return ("\(stored.username):\(stored.password)", true)
        }
        return nil
    }

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) {
        hub.emit(id, event)
    }

    // MARK: Blocking libcurl calls (dedicated threads, never the pool)

    private static func downloadBlocking(url: String, resumeFrom: Int64, userpwd: String?,
                                         requireTLS: Bool, maxBytesPerSecond: Int64,
                                         context: FTPTransferContext) async -> GCBResult {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(context)
            let thread = Thread {
                let result = gcb_download(url, resumeFrom, userpwd, requireTLS ? 1 : 0,
                                          maxBytesPerSecond,
                                          ftpWriteThunk, ftpProgressThunk, box.toOpaque())
                box.release()
                continuation.resume(returning: result)
            }
            thread.name = "goel.ftp-transfer"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    private static func remoteSizeBlocking(url: String, userpwd: String?,
                                           requireTLS: Bool) async -> (size: Int64, reachable: Bool) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                var reachable: Int32 = 0
                let size = Int64(gcb_remote_size(url, userpwd, requireTLS ? 1 : 0, &reachable))
                continuation.resume(returning: (size, reachable != 0))
            }
            thread.name = "goel.ftp-probe"
            thread.start()
        }
    }
}

// MARK: - Transfer context (shared with the curl callbacks)

/// Mutable per-transfer state the C callbacks reach through an opaque pointer:
/// the output file handle, byte counters, the abort flag, and the throttled
/// progress emitter. Lock-protected — callbacks arrive on the curl thread
/// while `abort()` comes from the engine actor.
final class FTPTransferContext: @unchecked Sendable {
    private let hub: EventHub
    private let id: UUID
    private let name: String
    private let handle: FileHandle
    private let resumeFrom: Int64

    private let lock = NSLock()
    private var aborted = false
    private var written: Int64 = 0
    private var totalHint: Int64 = 0
    private var meter: TransferProgressMeter

    init(hub: EventHub, id: UUID, name: String, handle: FileHandle, resumeFrom: Int64) {
        self.hub = hub
        self.id = id
        self.name = name
        self.handle = handle
        self.resumeFrom = resumeFrom
        self.meter = TransferProgressMeter(resumeFrom: resumeFrom)
    }

    var bytesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    func abort() {
        lock.lock(); defer { lock.unlock() }
        aborted = true
    }

    /// Write callback body. Returns false on a write failure (aborts curl). The
    /// shared meter announces the total once and throttles progress over the
    /// absolute offset (`resumeFrom + written`).
    func write(_ data: Data) -> Bool {
        do {
            try handle.write(contentsOf: data)
        } catch {
            return false
        }
        lock.lock()
        written += Int64(data.count)
        let tick = meter.step(total: totalHint, sofar: resumeFrom + written, now: Date())
        lock.unlock()
        if let announce = tick.announceTotal {
            hub.emit(id, .metadataResolved(
                name: name, totalBytes: announce,
                files: [TransferFile(id: 0, path: name, length: announce)]))
        }
        if let p = tick.progress {
            hub.emit(id, .progress(bytesDownloaded: p.bytes, bytesUploaded: 0,
                                   downloadSpeed: p.speed, uploadSpeed: 0,
                                   connectionCount: 1))
        }
        return true
    }

    /// Progress callback body: capture curl's size estimate, honour abort.
    func progress(dlTotal: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dlTotal > 0 { totalHint = resumeFrom + dlTotal }
        return !aborted
    }
}

/// C write thunk (`gcb_write`): forward the buffer to the context.
private func ftpWriteThunk(data: UnsafePointer<CChar>?, size: Int,
                           userdata: UnsafeMutableRawPointer?) -> Int {
    guard let data, let userdata else { return 0 }
    let context = Unmanaged<FTPTransferContext>.fromOpaque(userdata).takeUnretainedValue()
    let buffer = Data(bytes: data, count: size)
    return context.write(buffer) ? size : 0
}

/// C progress thunk (`gcb_progress`): nonzero return aborts the transfer.
private func ftpProgressThunk(userdata: UnsafeMutableRawPointer?,
                              dltotal: Int64, dlnow: Int64) -> Int32 {
    guard let userdata else { return 1 }
    let context = Unmanaged<FTPTransferContext>.fromOpaque(userdata).takeUnretainedValue()
    return context.progress(dlTotal: dltotal) ? 0 : 1
}
