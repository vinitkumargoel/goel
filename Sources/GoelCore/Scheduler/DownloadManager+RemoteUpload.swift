import Foundation

// MARK: - Sending a finished download to an SFTP server

/// The upload stage: everything that happens after a download completes and before its payload sits on the server the user chose.
///
/// Gated at the outermost entry point on ``AppSettings/sftpDestinationEnabled``, so with the feature off no session is opened, no Keychain entry is read, and no local file is ever deleted.
extension DownloadManager {

    /// Bytes a payload may occupy before its destination is worth preflighting for free space; below this the check costs more than it saves.
    static let remoteSpaceCheckThreshold: Int64 = 64 * 1024 * 1024

    // MARK: Entry point

    /// Start the upload for a freshly completed task, if it has a destination and the feature is on.
    func startRemoteUploadIfNeeded(_ task: DownloadTask) {
        guard settings.sftpDestinationEnabled else { return }
        guard let destination = task.remoteDestination, !destination.state.isFinished else { return }
        guard remoteUploadTasks[task.id] == nil else { return }

        let id = task.id
        remoteUploadTasks[id] = Task { [weak self] in
            await self?.runRemoteUpload(id)
            await self?.finishRemoteUploadTask(id)
        }
    }

    /// Clear the bookkeeping entry once an upload task ends, however it ended.
    func finishRemoteUploadTask(_ id: UUID) {
        remoteUploadTasks[id] = nil
        schedule()
    }

    /// Resume uploads interrupted by a quit or a crash. Anything left `.uploading` had its intent persisted before the first byte, so it is safe to restart — the temporary is removed and the transfer begins again.
    func resumeInterruptedRemoteUploads() {
        guard settings.sftpDestinationEnabled else { return }
        for task in tasks where task.status == .completed {
            guard let destination = task.remoteDestination else { continue }
            switch destination.state {
            case .uploading, .pending:
                startRemoteUploadIfNeeded(task)
            // Held means "the server refused for now" — a relaunch or a flag flip is exactly when that is worth re-testing. Failed is not: it needs the user to decide.
            case .held:
                startRemoteUploadIfNeeded(task)
            case .uploaded, .failed:
                continue
            }
        }
    }

    // MARK: Public actions

    /// Send an already-finished download to a server — the "Send to server" action on a completed task.
    ///
    /// Returns false when the feature is off, the task is missing, or its payload is gone. Deliberately a *copy*: the local file is only removed afterwards if `destination.removeLocalAfterUpload` was set, and only once the upload has verified.
    @discardableResult
    public func sendToServer(_ id: DownloadTask.ID, destination: RemoteDestination) async -> Bool {
        guard settings.sftpDestinationEnabled else { return false }
        guard let task = self.task(id), task.status == .completed else { return false }
        // `savePath` is the containing folder for a multi-file payload, and the transfer sends one file. Refused here so the caller learns immediately, rather than the destination being attached and failing later.
        guard !task.isMultiFile else { return false }
        guard FileManager.default.fileExists(atPath: task.savePath) else { return false }
        guard !task.isUploadingToRemote else { return false }

        var fresh = destination
        fresh.state = .pending
        fresh.attempt = 0
        fresh.bytesTransferred = 0
        fresh.failureMessage = nil
        mutateTask(id) { $0.remoteDestination = fresh }
        startRemoteUploadIfNeeded(self.task(id) ?? task)
        return true
    }

    /// Try a failed or held upload again, clearing the server's circuit breaker first so the user's explicit retry isn't swallowed by a backoff they can't see.
    public func retryRemoteUpload(_ id: DownloadTask.ID) async {
        guard settings.sftpDestinationEnabled else { return }
        guard let task = self.task(id), let destination = task.remoteDestination else { return }
        guard !destination.state.isInFlight, !destination.state.isFinished else { return }
        await uploadCoordinator.reset(server: destination.connectionID)
        markRemoteUpload(id, state: .pending, message: nil)
        startRemoteUploadIfNeeded(self.task(id) ?? task)
    }

    /// Stop an upload and leave the local copy in place. Awaits teardown, so it is safe to touch the payload once this returns.
    public func stopRemoteUpload(_ id: DownloadTask.ID) async {
        await cancelRemoteUpload(id)
        guard let destination = self.task(id)?.remoteDestination, !destination.state.isFinished else { return }
        markRemoteUpload(id, state: .failed, message: "Upload cancelled. The local copy is untouched.")
    }

    /// Forget a download's destination without touching anything already uploaded.
    public func clearRemoteDestination(_ id: DownloadTask.ID) async {
        await cancelRemoteUpload(id)
        mutateTask(id) { $0.remoteDestination = nil }
    }

    /// Servers currently refusing uploads, and why — so the UI can explain a stalled queue instead of showing silence.
    public func remoteUploadHolds() async -> [UUID: RemoteUploadCoordinator.Hold] {
        await uploadCoordinator.heldServers()
    }

    /// Clear a server's hold and retry everything waiting on it.
    public func clearRemoteUploadHold(server: UUID) async {
        await uploadCoordinator.reset(server: server)
        for task in tasks where task.remoteDestination?.connectionID == server {
            guard let destination = task.remoteDestination, destination.state == .failed || destination.state == .held else { continue }
            markRemoteUpload(task.id, state: .pending, message: nil)
            startRemoteUploadIfNeeded(self.task(task.id) ?? task)
        }
    }

    // MARK: The transfer

    private func runRemoteUpload(_ id: UUID) async {
        guard let task = self.task(id), let destination = task.remoteDestination else { return }

        // Re-checked here as well as at the entry point: the flag can be switched off between the two, and this is the last moment before anything leaves the machine.
        guard settings.sftpDestinationEnabled else {
            markRemoteUpload(id, state: .held, message: "Sending downloads to a server is turned off.")
            return
        }

        // `savePath` is a folder for a multi-file payload, and the transfer reads a single file. Refused here as well as in the UI so no entry point can queue one that is certain to fail.
        guard !task.isMultiFile else {
            markRemoteUpload(id, state: .failed, message: Self.multiFileRefusal)
            return
        }

        guard let connection = connectionStore.load().first(where: { $0.id == destination.connectionID }) else {
            markRemoteUpload(id, state: .held,
                             message: "The server \"\(destination.serverLabel)\" no longer exists. Choose another destination.")
            return
        }

        // Refuse to learn a host key without a person present. The upload runs unattended by definition — it fires whenever the download happens to finish — so trust-on-first-use here would pin whatever key answered.
        guard hostKeys.fingerprint(host: connection.host, port: connection.port) != nil else {
            markRemoteUpload(id, state: .failed,
                             message: "\(connection.label) has no trusted host key yet. Open the server in the browser once, so its identity can be checked.")
            return
        }

        // A timed backoff is waited out in place so the transfer resumes by itself; a manual hold needs a person, so say so rather than sitting queued in silence.
        if let hold = await awaitServerAvailability(destination.connectionID) {
            markRemoteUpload(id, state: .held, message: hold.message)
            return
        }
        guard !Task.isCancelled else {
            markRemoteUpload(id, state: .pending, message: nil)
            return
        }

        let plan: RemoteUploadPlan
        switch remoteUploadPlan(for: task, destination: destination) {
        case .success(let p): plan = p
        case .failure(let rejection):
            markRemoteUpload(id, state: .failed, message: rejection.message)
            return
        }

        let password = connectionStore.password(for: connection)
        guard let target = SFTPTarget(connection: connection, password: password) else {
            markRemoteUpload(id, state: .failed, message: "\(connection.label) is missing a host name.")
            return
        }
        let client = SFTPClient(target: target, hostKeys: hostKeys)

        // The slot is claimed *before* the preflight, because the preflight is itself two full TCP + SSH + auth handshakes. Running it outside the cap would let twenty downloads finishing together open twenty sessions at once — precisely what the cap exists to prevent.
        do {
            try await uploadCoordinator.acquire(server: destination.connectionID, remotePath: plan.finalPath)
        } catch let held as RemoteUploadCoordinator.ServerHeld {
            markRemoteUpload(id, state: .held, message: held.hold.message)
            return
        } catch {
            markRemoteUpload(id, state: .pending, message: nil)   // cancelled while queued; nothing was reserved
            return
        }
        defer {
            Task { await self.uploadCoordinator.release(server: destination.connectionID, remotePath: plan.finalPath) }
        }

        if let problem = await preflightRemoteDestination(client, plan: plan) {
            await recordRemoteFault(destination.connectionID, problem.fault)
            markRemoteUpload(id, state: .failed, message: problem.message)
            return
        }

        // Persisted before the first byte, so a crash mid-transfer is recoverable as "was uploading" rather than as silence.
        markRemoteUpload(id, state: .uploading, message: nil)

        let manager = UncheckedBox(self)
        do {
            try await client.uploadAtomic(
                localURL: URL(fileURLWithPath: plan.localPath),
                temporaryRemote: plan.temporaryPath,
                finalRemote: plan.finalPath,
                overwrite: false,
                maxBytesPerSecond: settings.effectiveProfile.maxUploadBytesPerSec,
                shouldContinue: { !Task.isCancelled },
                progress: { sent, _ in
                    Task { await manager.value.recordRemoteUploadProgress(id, bytes: sent) }
                })
        } catch let error as SFTPError where error.kind == .aborted {
            // Cancellation is not a failure. Shutting down and switching the feature off both cancel in-flight transfers, and those must come back by themselves rather than waiting on a manual retry the user has no reason to expect. An explicit Stop overwrites this with `.failed` once it has awaited teardown.
            markRemoteUpload(id, state: .pending, message: nil)
            return
        } catch let error as SFTPError {
            // Only a fault that describes the *server* reaches the breaker. A name collision or a size mismatch belongs to this download alone — pausing every other upload to the server because of one would be a far worse failure than the one being reported.
            await recordRemoteFault(destination.connectionID, Self.fault(for: error))
            markRemoteUpload(id, state: .failed, message: Self.remoteUploadMessage(for: error, server: connection.label))
            return
        } catch {
            markRemoteUpload(id, state: .failed, message: error.localizedDescription)
            return
        }

        await uploadCoordinator.recordSuccess(server: destination.connectionID)
        completeRemoteUpload(id, remotePath: plan.finalPath)
    }

    // MARK: Server availability

    /// Refused when a payload is a folder rather than a single file.
    public static let multiFileRefusal =
        "This download is a folder of files. Only single files can be sent to a server."

    /// Wait out a timed backoff so a transfer resumes on its own; return a manual hold, which no amount of waiting clears.
    ///
    /// The alternative — queueing behind every hold — is what makes a stalled server look like a stalled app: the upload sits `pending` with nothing to explain it and no point at which it gives up.
    private func awaitServerAvailability(_ server: UUID) async -> RemoteUploadCoordinator.Hold? {
        while let hold = await uploadCoordinator.currentHold(server) {
            guard case .backoff(let until) = hold else { return hold }
            let seconds = until.timeIntervalSinceNow
            guard seconds > 0 else { continue }   // expired in the gap; the next read clears it
            // Capped per sleep so a long backoff still notices cancellation promptly.
            do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 30) * 1_000_000_000)) }
            catch { return nil }                  // cancelled; the caller checks for that itself
        }
        return nil
    }

    /// Record a server-level fault, or nothing at all when the failure was scoped to one download.
    private func recordRemoteFault(_ server: UUID, _ fault: RemoteUploadCoordinator.Fault?) async {
        guard let fault else { return }
        await uploadCoordinator.recordFailure(server: server, fault: fault)
    }

    /// Which transfer failures say something about the server, and how badly.
    static func fault(for error: SFTPError) -> RemoteUploadCoordinator.Fault? {
        guard error.isServerScoped else { return nil }
        return error.isRetryable ? .transient(reason: error.message) : .unusable(reason: error.message)
    }

    // MARK: Preflight

    private struct RemoteProblem {
        var message: String
        /// nil when the problem is this destination's, not the server's — a missing folder must not pause every other upload.
        var fault: RemoteUploadCoordinator.Fault?
    }

    /// Confirm the destination is a real, writable directory that is not a symlink pointing outside the tree the user picked, and that there is room for the payload.
    private func preflightRemoteDestination(_ client: SFTPClient,
                                            plan: RemoteUploadPlan) async -> RemoteProblem? {
        let info: SFTPPathInfo
        do {
            info = try await client.pathInfo(plan.directory)
        } catch let error as SFTPError {
            return RemoteProblem(message: Self.remoteUploadMessage(for: error, server: plan.serverLabel),
                                 fault: Self.fault(for: error))
        } catch {
            return RemoteProblem(message: error.localizedDescription, fault: nil)
        }

        guard info.exists else {
            return RemoteProblem(message: "\(plan.directory) does not exist on \(plan.serverLabel). Create it first, or pick another folder.",
                                 fault: nil)
        }
        guard info.isDirectory else {
            return RemoteProblem(message: "\(plan.directory) is a file, not a folder.", fault: nil)
        }

        // A symlinked destination is followed by the server, so `/srv/incoming -> /etc` would write outside the chosen tree. Allowed only when the server confirms where it lands and that answer is still the same path.
        if info.isSymlink {
            guard let resolved = info.resolvedPath else {
                return RemoteProblem(message: "\(plan.directory) is a link and \(plan.serverLabel) will not say where it points. Pick the real folder instead.",
                                     fault: nil)
            }
            if !RemotePathSafety.isContained(resolved, within: plan.directory) {
                return RemoteProblem(message: "\(plan.directory) is a link to \(resolved). Pick that folder directly if it is what you meant.",
                                     fault: nil)
            }
        }

        // Owner-write is the best signal available without writing a probe file; a wrong guess still fails cleanly at open time and keeps the local copy.
        if info.permissions != 0 && (info.permissions & 0o200) == 0 {
            return RemoteProblem(message: "\(plan.directory) is not writable by \(plan.username).", fault: nil)
        }

        guard plan.expectedBytes >= Self.remoteSpaceCheckThreshold else { return nil }
        guard let space = try? await client.freeSpace(at: plan.directory), space.isSupported else {
            return nil   // the server doesn't answer statvfs — unknown, not full
        }
        if space.freeBytes < plan.expectedBytes {
            // Out of space is the server's problem, not this file's — every other upload to it will fail the same way, so back off rather than marching through the queue.
            return RemoteProblem(message: "\(plan.serverLabel) has \(space.freeBytes.byteString) free but the file needs \(plan.expectedBytes.byteString).",
                                 fault: .transient(reason: "No free space on \(plan.serverLabel)"))
        }
        return nil
    }

    // MARK: Planning

    /// Everything the transfer needs, resolved and validated before a session opens.
    struct RemoteUploadPlan {
        var directory: String
        var finalPath: String
        var temporaryPath: String
        var localPath: String
        var expectedBytes: Int64
        var serverLabel: String
        var username: String
    }

    /// Validate the destination folder and the file name, and build the paths. Every component of both is checked — a `..` in either would place the file outside the folder the user chose.
    func remoteUploadPlan(for task: DownloadTask,
                          destination: RemoteDestination) -> Result<RemoteUploadPlan, RemotePathSafety.Rejection> {
        let directory: String
        switch RemotePathSafety.validateDirectory(destination.directory) {
        case .success(let d): directory = d
        case .failure(let e): return .failure(e)
        }

        guard let name = RemotePathSafety.sanitizedComponent(task.name) else {
            return .failure(.unusableName)
        }
        let finalPath: String
        switch RemotePathSafety.join(directory: directory, relative: name) {
        case .success(let p): finalPath = p
        case .failure(let e): return .failure(e)
        }
        let temporaryPath: String
        switch RemotePathSafety.join(directory: directory,
                                     relative: RemotePathSafety.temporaryName(for: name, token: destination.token)) {
        case .success(let p): temporaryPath = p
        case .failure(let e): return .failure(e)
        }

        let localPath = task.savePath
        let size = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? task.totalBytes ?? 0

        let username = connectionStore.load().first { $0.id == destination.connectionID }?.username ?? ""
        return .success(RemoteUploadPlan(directory: directory,
                                         finalPath: finalPath,
                                         temporaryPath: temporaryPath,
                                         localPath: localPath,
                                         expectedBytes: size,
                                         serverLabel: destination.serverLabel,
                                         username: username))
    }

    // MARK: State transitions

    func markRemoteUpload(_ id: UUID, state: RemoteUploadState, message: String?) {
        mutateTask(id) { task in
            guard var destination = task.remoteDestination else { return }
            destination.state = state
            destination.failureMessage = message
            if state == .failed { destination.attempt += 1 }
            if state == .uploading { destination.bytesTransferred = 0 }
            task.remoteDestination = destination
        }
    }

    func recordRemoteUploadProgress(_ id: UUID, bytes: Int64) {
        guard let i = index(of: id), tasks[i].remoteDestination != nil else { return }
        tasks[i].remoteDestination?.bytesTransferred = bytes
        throttledPublish()
    }

    /// Record a verified upload, then remove the local copy only if the user asked for it.
    ///
    /// The delete is the last step of a chain that has already proved the file is intact: the bytes went to a temporary name, the server confirmed the size, and the rename into place succeeded. Any earlier failure returns before reaching here, so the local copy survives.
    private func completeRemoteUpload(_ id: UUID, remotePath: String) {
        guard let task = self.task(id), var destination = task.remoteDestination else { return }
        destination.state = .uploaded
        destination.remotePath = remotePath
        destination.failureMessage = nil
        destination.attempt = 0
        destination.bytesTransferred = task.totalBytes ?? destination.bytesTransferred
        let shouldRemoveLocal = destination.removeLocalAfterUpload
        let localPath = task.savePath
        let contained = task.isSavePathContained

        mutateTask(id) { $0.remoteDestination = destination }

        guard shouldRemoveLocal else { return }
        // The same containment check the engines make before any delete: a malformed name must never let a removal escape the download folder.
        guard contained else {
            FileHandle.standardError.write(Data(
                "[GoelDownloader] refusing to delete an uploaded payload outside its save directory: \(localPath)\n".utf8))
            return
        }
        Task.detached {
            try? FileManager.default.removeItem(atPath: localPath)
        }
    }

    // MARK: Cancellation

    /// Stop an in-flight upload and wait for the libssh2 thread to unwind.
    ///
    /// Ordering matters: the uploader holds an open read handle on the payload, so a caller that deletes or moves the file first would have it vanish mid-read. Callers must await this before touching local bytes.
    func cancelRemoteUpload(_ id: UUID) async {
        guard let task = remoteUploadTasks[id] else { return }
        task.cancel()
        _ = await task.value
        remoteUploadTasks[id] = nil
    }

    /// Cancel every in-flight upload and wait for them all — the flag being switched off, or the app shutting down.
    ///
    /// Drain rather than abandon: a killed transfer would leave a temporary file consuming space on the server, which nothing would ever clean up.
    func drainRemoteUploads() async {
        let running = remoteUploadTasks
        for (_, task) in running { task.cancel() }
        for (_, task) in running { _ = await task.value }
        remoteUploadTasks.removeAll()
    }

    // MARK: Staging budget

    /// Bytes committed to server-bound downloads that have not yet landed on their server.
    ///
    /// Counted from `totalBytes`, not from what has arrived: segmented HTTP preallocates the whole file at the first second, so a 154 GB download claims 154 GB immediately. Measuring progress instead would let the disk fill before the budget noticed.
    func stagedBytesAwaitingUpload() -> Int64 {
        tasks.reduce(into: Int64(0)) { total, task in
            guard let destination = task.remoteDestination, !destination.state.isFinished else { return }
            guard !task.status.isTerminal || task.status == .completed else { return }
            total += task.totalBytes ?? task.bytesDownloaded
        }
    }

    /// Whether new server-bound downloads should stay queued rather than start.
    ///
    /// The failure this prevents: a server goes offline, uploads stop draining, and every finished download sits in the staging area until the boot disk is full. Holding at the queue is the only point where that is still cheap to stop.
    func remoteStagingBudgetExceeded() -> Bool {
        guard settings.sftpDestinationEnabled else { return false }
        let cap = Int64(max(1, settings.sftpDestinationStagingBudgetGB)) * 1024 * 1024 * 1024
        return stagedBytesAwaitingUpload() >= cap
    }

    /// Drop server-bound tasks from a promotion batch when the staging budget is spent. Local downloads are unaffected — the budget is about payload waiting to be sent, not about downloads in general.
    func withinStagingBudget(_ promoted: [UUID]) -> [UUID] {
        guard remoteStagingBudgetExceeded() else { return promoted }
        return promoted.filter { id in
            guard let task = self.task(id) else { return true }
            return task.remoteDestination == nil
        }
    }

    // MARK: Messages

    /// Turn a transfer failure into something that says what to do about it.
    static func remoteUploadMessage(for error: SFTPError, server: String) -> String {
        switch error.kind {
        case .hostKeyMismatch:
            return "\(server)'s identity has changed. Nothing was sent. If the server was genuinely rebuilt, reset its pinned key in the connection settings."
        case .hostKey:
            return "\(server) did not present a host key. Nothing was sent."
        case .auth:
            return "\(server) rejected the sign-in. Check the password or SSH key for this server."
        case .resolve:
            return "Could not find \(server). Check the host name."
        case .connect:
            return "Could not reach \(server)."
        case .exists:
            return "A file with that name already exists on \(server). Rename the download or choose another folder."
        case .verify:
            return "The upload finished but \(server) reports a different size, so it was discarded. The local copy is untouched."
        case .rename:
            // The shim removes its temporary on any failure, rename included, rather than leaving an orphan eating the server's disk — so a retry re-sends the file rather than redoing just the rename.
            return "The file reached \(server) but could not be renamed into place, so the partial copy was removed. Retrying will send it again."
        case .aborted:
            return "Upload cancelled. The local copy is untouched."
        default:
            return error.message
        }
    }
}

/// Hands the actor-isolated manager to a C progress callback that cannot be `@Sendable`-checked; every use hops back onto the actor before touching state.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
