import Foundation

/// SFTP downloads over libssh2 (through ``SFTPClient`` / the ``SSHBridge`` C
/// shim). Structurally a twin of ``FTPEngine``: one blocking transfer per task
/// on a dedicated thread, byte-offset resume from the partial file's on-disk
/// size, per-task job serialization so a quick pause→resume never puts two
/// writers on one file, and a containment check before deleting.
///
/// Credentials come from the URL's inline userinfo or the Keychain (via the
/// connection store). Host keys are pinned trust-on-first-use in ``HostKeyStore``.
public actor SFTPEngine: DownloadEngine {

    public nonisolated let kind: DownloadKind = .sftp
    public nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata] }

    private nonisolated let hub = EventHub()

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var states: [UUID: SFTPDownloadState] = [:]
    private var profile: TrafficProfile

    public init(profile: TrafficProfile) {
        self.profile = profile
    }

    // MARK: DownloadEngine

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .sftp }

    public func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    public func pause(_ id: UUID) async {
        states[id]?.abort()
        jobs[id]?.cancel()
    }

    public func resume(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        startJob(id)
    }

    public func remove(_ id: UUID, deleteData: Bool) async {
        states[id]?.abort()
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        let task = tasks[id]
        tasks[id] = nil
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            try? FileManager.default.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    public func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    public nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    public func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source, source.kind == .sftp,
              let target = SFTPTarget(url: url) else { return nil }
        let name = PathSafety.sanitizedName(url.lastPathComponent, fallback: url.host ?? "download")
        let client = SFTPClient(target: target)
        let size = try? await client.size(url.path)
        return EngineMetadata(name: name, totalBytes: size, reachable: size != nil)
    }

    // MARK: Transfer

    private func startJob(_ id: UUID) {
        states[id]?.abort()
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
        guard let task = tasks[id], case .url(let url) = task.source,
              let target = SFTPTarget(url: url) else {
            let e = DownloadError.unknown("SFTPEngine requires an sftp:// source with a user and host")
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
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
        let resumeFrom = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            let e = DownloadError.fileMissing
            hub.fail(id, e)
            return
        }
        _ = try? handle.seekToEnd()

        let cap = profile.effectiveDownloadCap(taskLimit: task.speedLimitBytesPerSec)

        let state = SFTPDownloadState(hub: hub, id: id, name: task.name,
                                      handle: handle, resumeFrom: resumeFrom)
        states[id] = state
        defer { states[id] = nil }

        let client = SFTPClient(target: target)
        let result = await client.streamingDownload(
            remote: url.path, resumeFrom: resumeFrom, maxBytesPerSecond: cap,
            write: { buf in state.write(buf) },
            progress: { total, sofar in state.progress(total: total, sofar: sofar) })
        try? handle.close()

        if result.isAborted { return }   // our own pause/remove
        guard result.isSuccess else {
            let e = DownloadError.network(result.asError.message)
            hub.fail(id, e)
            return
        }

        let written = state.finalBytes
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

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }
}

/// Per-transfer state the SFTP callbacks reach: the output handle, the abort
/// flag, and the shared ``TransferProgressMeter`` (announce/throttle/speed).
/// Callbacks run on the transfer thread; `abort()` comes from the engine actor —
/// hence the lock.
final class SFTPDownloadState: @unchecked Sendable {
    private let hub: EventHub
    private let id: UUID
    private let name: String
    private let handle: FileHandle

    private let lock = NSLock()
    private var aborted = false
    private var meter: TransferProgressMeter

    init(hub: EventHub, id: UUID, name: String, handle: FileHandle, resumeFrom: Int64) {
        self.hub = hub
        self.id = id
        self.name = name
        self.handle = handle
        self.meter = TransferProgressMeter(resumeFrom: resumeFrom)
    }

    var finalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return meter.finalBytes
    }

    func abort() {
        lock.lock(); defer { lock.unlock() }
        aborted = true
    }

    func write(_ buf: UnsafeRawBufferPointer) -> Bool {
        do {
            try handle.write(contentsOf: Data(bytes: buf.baseAddress!, count: buf.count))
            return true
        } catch {
            return false
        }
    }

    /// libssh2 progress: `sofar` is the absolute downloaded byte count (it starts
    /// at `resumeFrom`). The shared meter announces the total once and throttles
    /// progress; this only emits what it returns and honours the abort flag.
    func progress(total: Int64, sofar: Int64) -> Bool {
        lock.lock()
        let tick = meter.step(total: total, sofar: sofar, now: Date())
        let stop = aborted
        lock.unlock()

        if let announce = tick.announceTotal {
            hub.emit(id, .metadataResolved(name: name, totalBytes: announce,
                                           files: [TransferFile(id: 0, path: name, length: announce)]))
        }
        if let p = tick.progress {
            hub.emit(id, .progress(bytesDownloaded: p.bytes, bytesUploaded: 0,
                                   downloadSpeed: p.speed, uploadSpeed: 0,
                                   connectionCount: 1))
        }
        return !stop
    }
}
