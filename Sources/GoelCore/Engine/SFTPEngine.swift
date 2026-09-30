import Foundation

/// Jobs are serialized per task: two concurrent writers on one file would corrupt it.
actor SFTPEngine: DownloadEngine {

    public nonisolated let kind: DownloadKind = .sftp
    nonisolated var capabilities: EngineCapabilities { [.resolvesMetadata] }

    private nonisolated let hub = EventHub()

    private var tasks: [UUID: DownloadTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var states: [UUID: SFTPDownloadState] = [:]
    private var profile: TrafficProfile

    init(profile: TrafficProfile) {
        self.profile = profile
    }

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
            RemoteTransferPrep.removeSavedFile(hub: hub, id: id, task: task)
        }
        hub.finishAll(id)
    }

    func applyLimits(_ profile: TrafficProfile) async { self.profile = profile }

    /// Renames, limits and credentials edited while paused apply to the next run; a running one keeps its snapshot.
    func refresh(_ task: DownloadTask) async {
        guard tasks[task.id] != nil else { return }
        tasks[task.id] = task
    }

    nonisolated func events(for id: UUID) -> AsyncStream<EngineEvent> { hub.subscribe(id) }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        guard case .url(let url) = source, source.kind == .sftp,
              let client = SFTPSession.client(for: url) else { return nil }
        let name = PathSafety.sanitizedName(url.lastPathComponent, fallback: url.host ?? "download")
        do {
            let size = try await client.size(url.path)
            return EngineMetadata(name: name, totalBytes: size)
        } catch {
            return EngineMetadata(name: name, totalBytes: nil, reachable: false,
                                  failureNote: Self.probeFailureNote(error))
        }
    }

    /// "Couldn't reach the server" must never stand in for a changed host key — that one may be an attack.
    static func probeFailureNote(_ error: Error) -> String {
        guard let e = error as? SFTPError else { return error.localizedDescription }
        if e.kind == .hostKeyMismatch { return "Security warning: \(e.message)" }
        return e.message
    }

    /// Identity and sign-in failures are not network trouble; saying so sends the user to check their Wi-Fi.
    static func downloadError(_ e: SFTPError) -> DownloadError {
        switch e.kind {
        case .hostKey, .hostKeyMismatch, .auth, .credentialsUnavailable:
            return .unknown(e.message)
        default:
            return .network(e.message)
        }
    }

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

        let remoteSize: Int64?
        do {
            remoteSize = try await client.size(url.path)
        } catch let e as SFTPError where [.hostKey, .hostKeyMismatch, .auth, .credentialsUnavailable].contains(e.kind) {
            // Nothing below can succeed, and a refused identity must not become a generic transfer error.
            if Task.isCancelled { return }
            hub.fail(id, Self.downloadError(e))
            return
        } catch {
            remoteSize = nil
        }
        // A pause during the probe only cancelled this task: no state existed yet to abort.
        if Task.isCancelled { return }
        let opened: RemoteTransferPrep.Opened
        do {
            opened = try RemoteTransferPrep.openForResume(
                saveDirectory: task.saveDirectory, savePath: task.savePath,
                remoteSize: remoteSize)
        } catch {
            hub.fail(id, RemoteTransferPrep.prepFailure(error, saveDirectory: task.saveDirectory,
                                                        log: GoelLog.engineSFTP))
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

        let result = await withTaskCancellationHandler {
            await client.streamingDownload(
                remote: url.path, resumeFrom: resumeFrom, maxBytesPerSecond: cap,
                write: { buf in state.write(buf) },
                progress: { total, sofar in state.progress(total: total, sofar: sofar) })
        } onCancel: {
            state.abort()
        }
        try? handle.close()

        // Before the abort check: a failed local write aborts the shim too, and ENOSPC is not a network error.
        if let writeError = state.writeError {
            let remaining = remoteSize.map { $0 - state.finalBytes }
            hub.fail(id, RemoteTransferPrep.writeFailure(writeError, fileURL: fileURL, needed: remaining,
                                                         log: GoelLog.engineSFTP))
            return
        }
        if result.isAborted { return }   // our own pause/remove
        guard result.isSuccess else {
            hub.fail(id, Self.downloadError(result.asError(host: client.target.host,
                                                           port: client.target.port,
                                                           username: client.target.username)))
            return
        }

        await RemoteTransferPrep.finishWithOptionalChecksum(
            hub: hub, id: id, name: task.name, fileURL: fileURL,
            written: state.finalBytes, expected: task.expectedChecksum)
    }

    private nonisolated func emit(_ id: UUID, _ event: EngineEvent) { hub.emit(id, event) }
}

/// Callbacks run on the transfer thread while `abort()` comes from the engine actor — hence the lock.
final class SFTPDownloadState: @unchecked Sendable {
    private let hub: EventHub
    private let id: UUID
    private let name: String
    private let handle: FileHandle

    private let lock = NSLock()
    private var aborted = false
    private var failedWrite: Error?
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

    /// Why the last local write failed; the shim only sees "aborted".
    var writeError: Error? {
        lock.lock(); defer { lock.unlock() }
        return failedWrite
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
            lock.lock(); failedWrite = error; lock.unlock()
            return false
        }
    }

    /// libssh2 `sofar` is absolute (it starts at `resumeFrom`), not a delta.
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
