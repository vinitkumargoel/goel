import Foundation

/// SFTP downloads over libssh2 (through ``SFTPClient`` / the ``SSHBridge`` C
/// shim). Structurally a twin of ``FTPEngine``: one blocking transfer per task
/// on a dedicated thread, byte-offset resume from the partial file's on-disk
/// size, per-task job serialization so a quick pause→resume never puts two
/// writers on one file, and a containment check before deleting.
///
/// Credentials come from the URL's inline userinfo or the Keychain (via the
/// connection store). Host keys are pinned trust-on-first-use in ``HostKeyStore``.
actor SFTPEngine: DownloadEngine {

    public nonisolated let kind: DownloadKind = .sftp
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata] }

    private nonisolated let hub = EventHub()
    /// Save-area filesystem seam (mkdir/create); see ``FileStoring``.
    private nonisolated let fileStore: any FileStoring

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var states: [UUID: SFTPDownloadState] = [:]
    private var profile: TrafficProfile

    init(profile: TrafficProfile, fileStore: any FileStoring = LocalFileStore()) {
        self.profile = profile
        self.fileStore = fileStore
    }

    // MARK: DownloadEngine

    public nonisolated func canHandle(_ source: DownloadSource) -> Bool { source.kind == .sftp }

    func add(_ task: DownloadTask) async {
        tasks[task.id] = task
        startJob(task.id)
    }

    func pause(_ id: UUID) async {
        states[id]?.abort()
        jobs[id]?.cancel()
    }

    func resume(_ id: UUID) async {
        guard tasks[id] != nil else { return }
        startJob(id)
    }

    func remove(_ id: UUID, deleteData: Bool) async {
        states[id]?.abort()
        let job = jobs[id]
        job?.cancel()
        jobs[id] = nil
        let task = tasks[id]
        tasks[id] = nil
        await job?.value
        if deleteData, let task, task.isSavePathContained {
            fileStore.removeItem(atPath: task.savePath)
        }
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source, source.kind == .sftp,
              let client = SFTPSession.client(for: url) else { return nil }
        let name = PathSafety.sanitizedName(url.lastPathComponent, fallback: url.host ?? "download")
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
              let client = SFTPSession.client(for: url) else {
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

        let remoteSize = try? await client.size(url.path)
        let opened: RemoteTransferPrep.Opened
        do {
            opened = try RemoteTransferPrep.openForResume(
                saveDirectory: task.saveDirectory, savePath: task.savePath,
                remoteSize: remoteSize, fileStore: fileStore)
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

        let state = SFTPDownloadState(hub: hub, id: id, name: task.name,
                                      handle: handle, resumeFrom: resumeFrom)
        states[id] = state
        defer { states[id] = nil }

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

        await RemoteTransferPrep.finishWithOptionalChecksum(
            hub: hub, id: id, name: task.name, fileURL: fileURL,
            written: state.finalBytes, expected: task.expectedChecksum)
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
            try handle.write(contentsOf: buf)
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
