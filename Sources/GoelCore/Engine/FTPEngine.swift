import Foundation
import CurlBridge

actor FTPEngine: DownloadEngine {

    public nonisolated let kind: DownloadKind = .ftp
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata] }

    private nonisolated let hub = EventHub()
    private nonisolated let credentialLookup: @Sendable (String) -> (username: String, password: String)?

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var contexts: [UUID: FTPTransferContext] = [:]
    private var profile: TrafficProfile

    init(profile: TrafficProfile,
                credentialLookup: (@Sendable (String) -> (username: String, password: String)?)? = nil) {
        self.profile = profile
        if let credentialLookup {
            self.credentialLookup = credentialLookup
        } else {
            let store = KeychainCredentialStore()
            self.credentialLookup = { host in store.credential(forHost: host) }
        }
    }

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .ftp }

    func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    func pause(_ id: UUID) async {
        contexts[id]?.abort()
        // Keep `jobs[id]`: the next start serializes on the old transfer actually finishing.
        jobs[id]?.cancel()
    }

    func resume(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        startJob(id)
    }

    func remove(_ id: UUID, deleteData: Bool) async {
        contexts[id]?.abort()
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        let task = tasks[id]
        tasks[id] = nil
        // Wait out the curl thread, or a re-added download at this path gets the old bytes.
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source, source.kind == .ftp else { return nil }
        let name = PathSafety.sanitizedName(url.lastPathComponent, fallback: url.host ?? "download")
        let credential = credentials(for: url)
        let probe = await Self.remoteSizeBlocking(url: url.absoluteString,
                                                  userpwd: credential?.userpwd,
                                                  requireTLS: credential?.requireTLS ?? false)
        // size == -1 means "no size advertised", not unreachable — don't conflate them.
        return EngineMetadata(name: name, totalBytes: probe.size >= 0 ? probe.size : nil,
                              reachable: probe.reachable)
    }

    private func startJob(_ id: UUID) {
        // Never overlap two transfers for one task — two writers on one file corrupt it.
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

        let credential = credentials(for: url)
        let probe = await Self.remoteSizeBlocking(
            url: url.absoluteString, userpwd: credential?.userpwd,
            requireTLS: credential?.requireTLS ?? false)
        let opened: RemoteTransferPrep.Opened
        do {
            opened = try RemoteTransferPrep.openForResume(
                saveDirectory: task.saveDirectory, savePath: task.savePath,
                remoteSize: probe.size >= 0 ? probe.size : nil)
        } catch {
            if let de = error as? DownloadError {
                hub.fail(id, de)
            } else {
                hub.fail(id, DownloadError.unknown("Couldn’t create the download folder"))
            }
            return
        }
        let handle = opened.handle
        let resumeFrom = opened.resumeFrom
        let fileURL = opened.fileURL

        let cap = profile.effectiveDownloadCap(taskLimit: task.speedLimitBytesPerSec)

        let context = FTPTransferContext(hub: hub, id: id, name: task.name,
                                         handle: handle, resumeFrom: resumeFrom)
        contexts[id] = context
        defer { contexts[id] = nil }

        let result = await Self.downloadBlocking(
            url: url.absoluteString, resumeFrom: resumeFrom,
            userpwd: credential?.userpwd,
            requireTLS: credential?.requireTLS ?? false,
            maxBytesPerSecond: cap, context: context)
        try? handle.close()

        if gcb_is_aborted(result.code) != 0 {
            return   // our own pause/remove; the manager owns the state
        }
        // run() must never touch jobs[id]: it may already hold a successor, breaking serialization.
        guard result.code == 0 else {
            let message = String(cString: gcb_error_message(result.code))
            let e = DownloadError.network(message)
            hub.fail(id, e)
            return
        }

        let written = resumeFrom + context.bytesWritten
        await RemoteTransferPrep.finishWithOptionalChecksum(
            hub: hub, id: id, name: task.name, fileURL: fileURL,
            written: written, expected: task.expectedChecksum)
    }

    /// Keychain logins ride TLS only — they fail rather than leak on a downgrade.
    private func credentials(for url: URL) -> (userpwd: String, requireTLS: Bool)? {
        // Inline userinfo counts only with a password: bare `ftp://user@host` must reach the Keychain.
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

/// Lock-protected: the curl thread races `abort()`.
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

    /// Returns false on a write failure, which aborts curl.
    func write(_ buf: UnsafeRawBufferPointer) -> Bool {
        do {
            try handle.write(contentsOf: buf)
        } catch {
            return false
        }
        lock.lock()
        written += Int64(buf.count)
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

    func progress(dlTotal: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dlTotal > 0 { totalHint = resumeFrom + dlTotal }
        return !aborted
    }
}

private func ftpWriteThunk(data: UnsafePointer<CChar>?, size: Int,
                           userdata: UnsafeMutableRawPointer?) -> Int {
    guard let data, size > 0, let userdata else { return 0 }
    let context = Unmanaged<FTPTransferContext>.fromOpaque(userdata).takeUnretainedValue()
    let buf = UnsafeRawBufferPointer(start: data, count: size)
    return context.write(buf) ? size : 0
}

/// Nonzero return aborts the transfer.
private func ftpProgressThunk(userdata: UnsafeMutableRawPointer?,
                              dltotal: Int64, dlnow: Int64) -> Int32 {
    guard let userdata else { return 1 }
    let context = Unmanaged<FTPTransferContext>.fromOpaque(userdata).takeUnretainedValue()
    return context.progress(dlTotal: dltotal) ? 0 : 1
}
