import Foundation
import GoelCore

@MainActor
extension AppViewModel {
    func startUpload(items: [URL], toRemoteDir remoteDir: String, on connection: SFTPConnection) {
        guard !items.isEmpty else { return }
        // `prepareUpload` resolves its own client; resolving twice prompts for Keychain access twice for one drop.
        Task { await self.prepareUpload(items: items, remoteDir: remoteDir, connection: connection) }
    }

    func resolveUploadConflicts(_ request: SFTPUploadConflictRequest,
                                decisions: [UUID: SFTPUploadConflictRequest.Policy]) {
        sftpUploadConflicts = nil
        // Renamed uploads must dodge the existing remote names *and* the free items in this same batch.
        var taken = request.existing
        request.free.forEach { taken.insert($0.url.lastPathComponent) }

        var plan: [PlannedUpload] = request.free.map {
            PlannedUpload(url: $0.url, isDirectory: $0.isDirectory, name: $0.url.lastPathComponent)
        }
        for item in request.colliding {
            switch decisions[item.id] ?? .rename {
            case .skip:
                continue
            case .overwrite:
                plan.append(PlannedUpload(url: item.url, isDirectory: item.isDirectory, name: item.name))
            case .resume:
                plan.append(PlannedUpload(url: item.url, isDirectory: item.isDirectory, name: item.name,
                                          resuming: true))
            case .rename:
                let unique = SFTPBrowserPaths.uniqueName(item.name, existing: taken)
                taken.insert(unique)
                plan.append(PlannedUpload(url: item.url, isDirectory: item.isDirectory, name: unique))
            }
        }
        guard !plan.isEmpty else { return }
        guard let client = sftpClientReportingFailure(for: request.connection) else { return }
        launchUploads(connection: request.connection, remoteDir: request.remoteDir,
                      plan: plan, client: client)
    }

    func startDownload(_ entry: SFTPEntry, from connection: SFTPConnection,
                       remoteDir: String, toLocalDir localDir: URL) {
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        // The entry name is server-supplied: sanitize to one safe component so it can't steer the local path.
        let safeName = PathSafety.sanitizedName(entry.name)
        // `downloadToFile` truncate-creates, so an existing local file dies silently; without a listing, refuse rather than guess.
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: localDir.path) else {
            toastNow(L10n.t("Couldn’t read “%1$@”, so “%2$@” wasn’t downloaded.",
                            localDir.lastPathComponent, entry.name))
            return
        }
        var existingNames = Set(listed)
        // Queued downloads haven't created their files yet and every dotfile sanitizes to "download", so reserve names already heading here — paused rows still own theirs.
        existingNames.formUnion(sftpTransfers.lazy
            .filter { $0.direction == .download && $0.occupiesDestination
                && $0.localURL?.deletingLastPathComponent().standardizedFileURL == localDir.standardizedFileURL }
            .compactMap { $0.localURL?.lastPathComponent })
        let localName = SFTPBrowserPaths.uniqueName(safeName, existing: existingNames)
        let destination = localDir.appendingPathComponent(localName)
        guard SFTPBrowserModel.isContained(destination, in: localDir) else {
            toastNow(L10n.t("Refusing to write “%@” outside the chosen folder.", entry.name)); return
        }
        let remoteSource = SFTPBrowserPaths.join(remoteDir, entry.name)
        let cancel = CancelFlag()
        let transfer = SFTPTransfer(connectionID: connection.id, name: localName, direction: .download,
                                    isDirectory: entry.isDirectory, localURL: destination,
                                    remotePath: remoteSource,
                                    // A folder's listed size is its inode's, not its contents'; the real total lands after the walk.
                                    total: entry.isDirectory ? 0 : entry.size)
        sftpTransfers.append(transfer)
        let id = transfer.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(id: id, client: client,
                                   remoteSource: remoteSource, destination: destination,
                                   cancel: cancel, isDirectory: entry.isDirectory)
        }
        sftpTransferTasks[id] = (task, cancel)
    }

    func requestCancelSFTPTransfer(_ id: UUID) {
        guard let t = sftpTransfers.first(where: { $0.id == id }) else { return }
        // A paused transfer still owns real progress; cancelling it deserves the same confirmation.
        guard t.isActive || t.isPaused else { cancelSFTPTransfer(id); return }
        let verb = t.cancelNoun
        requestConfirm(
            title: L10n.t("Cancel this %@?", L10n.t(verb)),
            message: L10n.t("“%@” will stop transferring and be removed from the list.", t.name),
            confirmTitle: L10n.t("Stop Transfer"),
            destructive: true
        ) { [weak self] in self?.cancelSFTPTransfer(id) }
    }

    func cancelSFTPTransfer(_ id: UUID) {
        if let entry = sftpTransferTasks[id] {
            entry.cancel.cancel()
            entry.task.cancel()
        }
        // A paused download's partial lives on for resume; cancelling abandons it, so
        // clean it up here — the run task that normally does this is long gone.
        if let t = sftpTransfers.first(where: { $0.id == id }), t.isPaused,
           t.direction == .download, let partial = t.localURL {
            try? FileManager.default.removeItem(at: partial)
        }
        sftpPauseIntents.remove(id)
        sftpTransferTasks[id] = nil
        sftpFolderBytes[id] = nil
        sftpRemoteCopyPlans[id] = nil
        sftpTransfers.removeAll { $0.id == id }
        toastNow(L10n.t("Transfer cancelled"))
    }

    /// The abort travels through the same cancel flag; `sftpPauseIntents` tells the
    /// settle path to park the row as `.paused` with its partial file intact.
    func pauseSFTPTransfer(_ id: UUID) {
        guard let t = sftpTransfers.first(where: { $0.id == id }), t.canPause,
              let entry = sftpTransferTasks[id] else { return }
        sftpPauseIntents.insert(id)
        entry.cancel.cancel()
        entry.task.cancel()
    }

    func resumeSFTPTransfer(_ id: UUID) {
        guard let t = sftpTransfers.first(where: { $0.id == id }), t.canResume else { return }
        retrySFTPTransfer(id)
    }

    /// Relaunches a paused, failed, or cancelled transfer. Not a free replay: the destination
    /// has moved on, so the first attempt's checks run again — but bytes that verifiably
    /// landed (remote size for uploads, local partial for downloads) are never re-sent.
    func retrySFTPTransfer(_ id: UUID) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }), !sftpTransfers[i].isActive else { return }
        let t = sftpTransfers[i]
        guard let connection = server(t.connectionID) else { toastNow(L10n.t("That server no longer exists.")); return }
        // Resolve before flipping the row live: a refused Keychain read must leave the row failed, not "running".
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        // Marked waiting *before* the preflight, so this row reserves its destination against a transfer started meanwhile.
        sftpTransfers[i].state = .waiting
        sftpTransfers[i].resetProgress()
        let cancel = CancelFlag()
        let task = Task { [weak self] in
            guard let self else { return }
            guard let localURL = t.localURL else {
                self.settleTransfer(id, .failed(L10n.t("This transfer can’t be retried.")))
                return
            }
            switch t.direction {
            case .upload:
                guard await self.retriedUploadIsStillAuthorised(id: id, client: client,
                                                                remoteTarget: t.remotePath,
                                                                isDir: t.isDirectory) else { return }
                await self.runUpload(id: id, client: client, localURL: localURL,
                                     isDir: t.isDirectory, remoteTarget: t.remotePath, cancel: cancel,
                                     resuming: true)
            case .download:
                guard let destination = self.retriedDownloadDestination(id: id, current: localURL)
                else { return }
                await self.runDownload(id: id, client: client,
                                       remoteSource: t.remotePath, destination: destination,
                                       cancel: cancel, isDirectory: t.isDirectory,
                                       resuming: destination == localURL)
            case .remoteCopy:
                await self.runRemoteCopy(id: id, cancel: cancel)
            }
        }
        sftpTransferTasks[id] = (task, cancel)
    }

    private func retriedDownloadDestination(id: UUID, current: URL) -> URL? {
        let directory = current.deletingLastPathComponent()
        var listing = DirectoryListing.unavailable
        if let listed = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var taken = Set(listed)
            // The file at the row's own path is its kept partial — the very thing resume
            // continues from. Counting it as "taken" would rename away and restart at zero.
            taken.remove(current.lastPathComponent)
            // Every *other* download here has reserved its name; this row is excluded so it may keep the name it holds.
            taken.formUnion(sftpTransfers.lazy
                .filter { $0.id != id && $0.direction == .download && $0.occupiesDestination
                    && $0.localURL?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }
                .compactMap { $0.localURL?.lastPathComponent })
            listing = .names(taken)
        }
        guard let name = SFTPOverwritePlan.retryName(current.lastPathComponent, against: listing) else {
            settleTransfer(id, .failed(L10n.t("Couldn’t read “%@” — nothing was downloaded.",
                                              directory.lastPathComponent)))
            return nil
        }
        guard name != current.lastPathComponent else { return current }
        let destination = directory.appendingPathComponent(name)
        guard SFTPBrowserModel.isContained(destination, in: directory) else {
            settleTransfer(id, .failed(L10n.t("Refusing to write “%@” outside the chosen folder.",
                                              name)))
            return nil
        }
        if let i = sftpTransfers.firstIndex(where: { $0.id == id }) {
            sftpTransfers[i].localURL = destination
            sftpTransfers[i].name = name
        }
        return destination
    }

    private func retriedUploadIsStillAuthorised(id: UUID, client: SFTPClient,
                                                remoteTarget: String, isDir: Bool) async -> Bool {
        let parent = SFTPBrowserPaths.parent(of: remoteTarget)
        let place = parent == "." ? L10n.t("Home") : parent
        let entries: [SFTPEntry]
        do {
            entries = try await client.list(parent)
        } catch let e as SFTPError {
            settleTransfer(id, .failed(
                L10n.t("Couldn’t check what’s already in %1$@ — nothing was uploaded. %2$@",
                       place, e.message)))
            return false
        } catch {
            settleTransfer(id, .failed(
                L10n.t("Couldn’t check what’s already in %@ — nothing was uploaded.", place)))
            return false
        }
        let name = (remoteTarget as NSString).lastPathComponent
        if !isDir, entries.contains(where: { $0.name == name && $0.isDirectory }) {
            settleTransfer(id, .failed(
                L10n.t("“%@” is a folder on the server now — nothing was uploaded.", name)))
            return false
        }
        return true
    }

    func clearFinishedSFTPTransfers() {
        let before = sftpTransfers.count
        // Paused rows are not finished — clearing one would strand its partial file.
        let dropped = Set(sftpTransfers.lazy.filter { !$0.occupiesDestination }.map(\.id))
        sftpTransfers.removeAll { dropped.contains($0.id) }
        for id in dropped { sftpRemoteCopyPlans[id] = nil }
        if sftpTransfers.count != before { toastNow(L10n.t("Cleared finished transfers")) }
    }

    func sftpTransfers(for connectionID: UUID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.connectionID == connectionID }
    }

    private func prepareUpload(items: [URL], remoteDir: String, connection: SFTPConnection) async {
        // Classify before resolving the client so an unsendable batch raises no Keychain prompt; an unreadable stat must not default to "file" — upload truncate-creates.
        var isDirectories: [Bool] = []
        for url in items {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = values.isDirectory else {
                toastNow(L10n.t("Couldn’t read “%@” — nothing was uploaded.", url.lastPathComponent))
                return
            }
            isDirectories.append(isDirectory)
        }

        guard let client = sftpClientReportingFailure(for: connection) else { return }
        let listing: DirectoryListing
        var listingDetail: String?
        do {
            listing = .names(Set(try await client.list(remoteDir).map(\.name)))
        } catch let e as SFTPError {
            listing = .unavailable
            listingDetail = e.message
        } catch {
            listing = .unavailable
        }

        // A directory we couldn't read is not an empty one: treating it as empty authorises TRUNC over files nobody was asked about.
        guard case .names(let existing) = listing,
              let split = SFTPOverwritePlan.split(names: items.map(\.lastPathComponent),
                                                  against: listing) else {
            let place = remoteDir == "." ? L10n.t("Home") : remoteDir
            toastNow(L10n.t("Couldn’t check what’s already in %@ — nothing was uploaded.", place)
                     + (listingDetail.map { " \($0)" } ?? ""))
            return
        }
        func item(_ index: Int) -> SFTPUploadConflictRequest.Item {
            SFTPUploadConflictRequest.Item(url: items[index], isDirectory: isDirectories[index])
        }
        let free = split.free.map(item)
        let colliding = split.colliding.map(item)
        if colliding.isEmpty {
            launchUploads(connection: connection, remoteDir: remoteDir,
                          plan: free.map { PlannedUpload(url: $0.url, isDirectory: $0.isDirectory,
                                                         name: $0.url.lastPathComponent) },
                          client: client)
        } else {
            sftpUploadConflicts = SFTPUploadConflictRequest(connection: connection, remoteDir: remoteDir,
                                                            existing: existing, free: free, colliding: colliding)
        }
    }

    private func launchUploads(connection: SFTPConnection, remoteDir: String,
                               plan: [PlannedUpload], client: SFTPClient) {
        for item in plan {
            let remoteTarget = SFTPBrowserPaths.join(remoteDir, item.name)
            let cancel = CancelFlag()
            let transfer = SFTPTransfer(connectionID: connection.id, name: item.name, direction: .upload,
                                        isDirectory: item.isDirectory, localURL: item.url, remotePath: remoteTarget)
            sftpTransfers.append(transfer)
            let id = transfer.id
            let url = item.url, isDir = item.isDirectory, resuming = item.resuming
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runUpload(id: id, client: client, localURL: url,
                                     isDir: isDir, remoteTarget: remoteTarget, cancel: cancel,
                                     resuming: resuming)
            }
            sftpTransferTasks[id] = (task, cancel)
        }
    }

    /// Takes an already-resolved `client`: the Keychain can prompt on every read, so a 20-file drop would raise 20 prompts.
    private func runUpload(id: UUID, client baseClient: SFTPClient, localURL: URL, isDir: Bool,
                           remoteTarget: String, cancel: CancelFlag, resuming: Bool = false) async {
        let cap = settings.effectiveProfile.maxUploadBytesPerSec
        // One connection for the whole job, so a 500-file folder pays one handshake; released on every exit path below.
        let client = baseClient.forTransfer(id)
        do {
            if isDir {
                try await uploadFolder(id: id, client: client, root: localURL,
                                       remoteRoot: remoteTarget, cap: cap, cancel: cancel,
                                       resuming: resuming)
            } else {
                let total = Self.fileSize(localURL)
                setTransferTotal(id, total)
                // Only bytes the server confirms holding can be skipped; anything else re-sends from zero.
                var resumeFrom: Int64 = 0
                if resuming {
                    // Stat twice before giving up: a transient failure here silently re-sends
                    // (and truncates) the whole file from zero.
                    var existing = try? await client.attributes(remoteTarget, followSymlink: true)
                    if existing == nil {
                        existing = try? await client.attributes(remoteTarget, followSymlink: true)
                    }
                    if let existing, existing.exists, !existing.isDirectory, existing.size <= total {
                        resumeFrom = existing.size
                        // Noted before the offset is played in, so the row's average and
                        // its "already on the server" figure both discount these bytes.
                        setTransferResumeOffset(id, resumeFrom)
                        setTransferBytes(id, resumeFrom)
                    }
                }
                if resuming, total > 0, resumeFrom == total {
                    // The server already holds every byte — settle finished without
                    // reopening handles, like the folder path's equal-size skip.
                    setTransferBytes(id, total)
                } else {
                    let coalescer = ProgressCoalescer()
                    try await client.upload(localURL: localURL, remote: remoteTarget,
                                            resumeFrom: resumeFrom, maxBytesPerSecond: cap,
                                            shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                        guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                        // Bound inside this callback, not the Task: the capture list makes `self` a var and older toolchains reject reading one from concurrent code.
                        guard let self else { return }
                        Task { @MainActor in self.setTransferBytes(id, sofar) }
                    }
                }
            }
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        await client.finishTransfer(id)
        // Any outcome may have created or partially written remote files (libssh2 opens with CREAT), so always refresh.
        bumpMutation()
    }

    /// 3, not 4: one stream already saturates a home link since the sliding-window shim,
    /// and the slimmer footprint leaves pool slots free for transfers started alongside.
    /// Also read by the transfer inspector, which reports a folder's stream count.
    static let maxParallelUploads = 3

    private func uploadFolder(id: UUID, client: SFTPClient, root: URL,
                              remoteRoot: String, cap: Int64, cancel: CancelFlag,
                              resuming: Bool = false) async throws {
        let scan = await Task.detached { FolderScan(scanning: root) }.value
        // A failed or partial walk would otherwise settle as a finished upload of an empty tree — failure reported as success.
        guard !scan.enumerationFailed else {
            throw SFTPError(kind: .io,
                            message: L10n.t("Couldn’t read “%@” — nothing was uploaded.", root.lastPathComponent))
        }
        if let first = scan.unreadable.first {
            let others = scan.unreadable.count - 1
            throw SFTPError(kind: .io,
                            message: L10n.t("Couldn’t read “%1$@”%2$@ inside “%3$@” — nothing was uploaded.",
                                            first,
                                            others == 0 ? ""
                                                : others == 1 ? L10n.t(" and %d more item", others)
                                                              : L10n.t(" and %d more items", others),
                                            root.lastPathComponent))
        }
        setTransferTotal(id, scan.total)
        sftpFolderBytes[id] = [:]

        // Shallowest → deepest so every file's parent exists; `makeDirectory` still raises denied/quota/name-taken, which a blanket `try?` swallowed.
        try await SFTPRelay.makeDirectory(remoteRoot, on: client)
        for rel in scan.dirs.sorted(by: { $0.count < $1.count }) {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: L10n.t("Cancelled")) }
            try await SFTPRelay.makeDirectory(rel.reduce(remoteRoot, SFTPBrowserPaths.join),
                                              on: client)
        }

        let files = scan.files
        guard !files.isEmpty else { return }
        let parallel = min(Self.maxParallelUploads, files.count)
        // Split the global cap across streams so N parallel transfers still respect the one profile limit (0 = unlimited).
        let perStreamCap = cap > 0 ? max(1, cap / Int64(parallel)) : 0

        let cursor = UploadCursor()
        let streamIDs = (0..<parallel).map { _ in UUID() }
        defer {
            // Detached because `defer` cannot await, and these must return to the pool even when the group throws.
            let ids = streamIDs
            Task.detached { for streamID in ids { await client.finishTransfer(streamID) } }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for streamID in streamIDs {
                let stream = client.forTransfer(streamID)
                group.addTask { [weak self] in
                    // Read the capture into an immutable local: reading a capture-list var inside a @Sendable closure is an error in Swift 6.
                    let model = self
                    while let index = await cursor.next(limit: files.count) {
                        if cancel.isCancelled { throw SFTPError(kind: .aborted, message: L10n.t("Cancelled")) }
                        let file = files[index]
                        let remoteFile = file.rel.reduce(remoteRoot, SFTPBrowserPaths.join)
                        // On resume, bytes the server already holds are skipped — a whole
                        // file when sizes match, a tail when the server holds a prefix.
                        var resumeFrom: Int64 = 0
                        if resuming, let existing = try? await stream.attributes(remoteFile, followSymlink: true),
                           existing.exists, !existing.isDirectory, existing.size <= file.size {
                            if existing.size == file.size, file.size > 0 {
                                if let model {
                                    await MainActor.run {
                                        model.setFolderFileBytes(id, index: index, bytes: file.size)
                                        // Counted as progress above, so it must also be
                                        // counted as skipped or the average inflates.
                                        model.addTransferResumed(id, file.size)
                                    }
                                }
                                continue
                            }
                            resumeFrom = existing.size
                            // Immutable copy: reading a captured var inside a @Sendable
                            // closure is an error in the Swift 6 language mode.
                            let skipped = resumeFrom
                            if skipped > 0, let model {
                                await MainActor.run { model.addTransferResumed(id, skipped) }
                            }
                        }
                        let coalescer = ProgressCoalescer()
                        try await stream.upload(localURL: file.url, remote: remoteFile,
                                                resumeFrom: resumeFrom,
                                                maxBytesPerSecond: perStreamCap,
                                                shouldContinue: { !cancel.isCancelled }) { sofar, total in
                            guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                            guard let model else { return }
                            Task { @MainActor in model.setFolderFileBytes(id, index: index, bytes: sofar) }
                        }
                        // Pin the file's full size on completion so the aggregate lands exactly on the total even if the last tick arrived before EOF.
                        if let model {
                            await MainActor.run { model.setFolderFileBytes(id, index: index, bytes: file.size) }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private actor UploadCursor {
        private var index = 0
        func next(limit: Int) -> Int? {
            guard index < limit else { return nil }
            defer { index += 1 }
            return index
        }
    }

    private func runDownload(id: UUID, client baseClient: SFTPClient, remoteSource: String,
                             destination: URL, cancel: CancelFlag, isDirectory: Bool = false,
                             resuming: Bool = false) async {
        let cap = settings.effectiveProfile.maxDownloadBytesPerSec
        let client = baseClient.forTransfer(id)
        var succeeded = false
        do {
            if isDirectory {
                try await downloadFolder(id: id, client: client, remoteRoot: remoteSource,
                                         localRoot: destination, cap: cap, cancel: cancel,
                                         resuming: resuming)
            } else {
                // A partial smaller than the remote file continues from where it stopped;
                // a larger or shrunk remote starts over from zero.
                var resumeFrom: Int64 = 0
                var alreadyComplete = false
                if resuming {
                    let localSize = Self.fileSize(destination)
                    if localSize > 0 {
                        // A failed size check must fail the transfer (which keeps the
                        // partial), not guess "no resume" — that guess truncates the
                        // partial and silently starts over from zero. Checked twice
                        // so one transient hiccup doesn't fail an otherwise-good retry.
                        var sized = try? await client.size(remoteSource)
                        if sized == nil { sized = try? await client.size(remoteSource) }
                        guard let remoteSize = sized else {
                            throw SFTPError(kind: .io,
                                            message: L10n.t("Could not check how much of the file the server has — the partial download was kept. Try again."))
                        }
                        if localSize == remoteSize {
                            // Every byte is already on disk — settle finished without
                            // truncating or reopening anything.
                            alreadyComplete = true
                            setTransferResumeOffset(id, localSize)
                            setTransferProgress(id, bytes: localSize, total: remoteSize)
                        } else if localSize < remoteSize {
                            resumeFrom = localSize
                            setTransferResumeOffset(id, resumeFrom)
                            setTransferBytes(id, resumeFrom)
                        }
                    }
                }
                if !alreadyComplete {
                    let coalescer = ProgressCoalescer()
                    try await client.downloadToFile(remote: remoteSource, localURL: destination,
                                                    resumeFrom: resumeFrom, maxBytesPerSecond: cap,
                                                    shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                        guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                        guard let self else { return }
                        Task { @MainActor in self.setTransferProgress(id, bytes: sofar, total: total) }
                    }
                }
            }
            succeeded = true
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        await client.finishTransfer(id)
        // Keep the partial for paused and failed rows — that's what resume continues from.
        // A missing row means the user cancelled: discard, as the old always-delete did.
        if !succeeded {
            let rowState = sftpTransfers.first(where: { $0.id == id })?.state
            let keep: Bool
            switch rowState {
            case .paused, .failed: keep = true
            default: keep = false
            }
            if !keep { try? FileManager.default.removeItem(at: destination) }
        }
    }

    private func downloadFolder(id: UUID, client: SFTPClient, remoteRoot: String,
                                localRoot: URL, cap: Int64, cancel: CancelFlag,
                                resuming: Bool = false) async throws {
        let plan = try await SFTPRelay.walk(client.onBackground(), root: remoteRoot,
                                            shouldContinue: { !cancel.isCancelled })
        // A walk that skipped an entry would silently download a partial tree and then report it as complete.
        try SFTPRelay.requireComplete(plan)
        // Same reason for links: the bridge can read one but the download path can't reproduce it,
        // so the folder would arrive missing entries and still be marked finished.
        try SFTPRelay.requireNoLinks(plan, root: remoteRoot)
        setTransferTotal(id, plan.files.reduce(0) { $0 + $1.size })
        sftpFolderBytes[id] = [:]

        // Sanitising is lossy (every dotfile collapses to "download"), so distinct remote names collide and parallel streams would truncate each other.
        let layout = try Self.localLayout(for: plan, under: localRoot)

        // Directories first, shallowest first, so every file has a parent.
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        for url in layout.directories {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: L10n.t("Cancelled")) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let files = plan.files
        guard !files.isEmpty else { return }
        let parallel = min(Self.maxParallelUploads, files.count)
        let perStreamCap = cap > 0 ? max(1, cap / Int64(parallel)) : 0

        let cursor = UploadCursor()
        let streamIDs = (0..<parallel).map { _ in UUID() }
        defer {
            let ids = streamIDs
            Task.detached { for streamID in ids { await client.finishTransfer(streamID) } }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for streamID in streamIDs {
                let stream = client.forTransfer(streamID)
                group.addTask { [weak self] in
                    let model = self
                    while let index = await cursor.next(limit: files.count) {
                        if cancel.isCancelled { throw SFTPError(kind: .aborted, message: L10n.t("Cancelled")) }
                        let file = files[index]
                        let local = layout.files[index]
                        let remote = file.relative.reduce(remoteRoot, SFTPBrowserPaths.join)
                        // On resume, a local file matching the remote size is done; a smaller
                        // one continues from its end. Layout pairing is deterministic, so the
                        // partial on disk belongs to this remote file.
                        var resumeFrom: Int64 = 0
                        if resuming {
                            let localSize = Self.fileSize(local)
                            if localSize == file.size, file.size > 0 {
                                if let model {
                                    await MainActor.run {
                                        model.setFolderFileBytes(id, index: index, bytes: file.size)
                                        // Counted as progress above, so it must also be
                                        // counted as skipped or the average inflates.
                                        model.addTransferResumed(id, file.size)
                                    }
                                }
                                continue
                            }
                            if localSize > 0, localSize < file.size {
                                resumeFrom = localSize
                                if let model {
                                    await MainActor.run { model.addTransferResumed(id, localSize) }
                                }
                            }
                        }
                        let coalescer = ProgressCoalescer()
                        try await stream.downloadToFile(remote: remote, localURL: local,
                                                        resumeFrom: resumeFrom,
                                                        maxBytesPerSecond: perStreamCap,
                                                        shouldContinue: { !cancel.isCancelled }) { sofar, total in
                            guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                            guard let model else { return }
                            Task { @MainActor in model.setFolderFileBytes(id, index: index, bytes: sofar) }
                        }
                        if let model {
                            await MainActor.run { model.setFolderFileBytes(id, index: index, bytes: file.size) }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    struct LocalLayout {
        let directories: [URL]
        /// One URL per file in the plan, in the plan's own order.
        let files: [URL]
    }

    /// Names are untrusted and sanitising is lossy, so each directory tracks claimed names and a collision takes a "name (2)" sibling.
    nonisolated static func localLayout(for plan: SFTPRelay.TreePlan,
                                        under root: URL) throws -> LocalLayout {
        var resolved: [[String]: URL] = [[]: root]
        var claimed: [String: Set<String>] = [:]

        func place(_ relative: [String], isDirectory: Bool) throws -> URL {
            let parentPath = Array(relative.dropLast())
            guard let name = relative.last, let parent = resolved[parentPath] else {
                throw SFTPError(kind: .io,
                                message: L10n.t("Couldn’t work out where to save “%@”.",
                                                relative.joined(separator: "/")))
            }
            guard SFTPBrowserPaths.isSafeChildName(name) else {
                throw SFTPError(kind: .io,
                                message: L10n.t("The server sent an item named “%@”, which Goel won’t write to disk.", name))
            }
            let key = parent.standardizedFileURL.path
            var taken = claimed[key] ?? []
            let unique = SFTPBrowserPaths.uniqueName(PathSafety.sanitizedName(name), existing: taken)
            taken.insert(unique)
            claimed[key] = taken

            let url = parent.appendingPathComponent(unique)
            // Belt and braces on top of the per-component checks: the final path must still resolve inside the folder the user chose.
            guard PathSafety.isContained(url.path, within: root.path) else {
                throw SFTPError(kind: .io, message: L10n.t("Refusing to write outside the download folder."))
            }
            if isDirectory { resolved[relative] = url }
            return url
        }

        // Shallowest first, so a directory is placed before its children look up its resolved name.
        let directories = try plan.directories
            .sorted { $0.count < $1.count }
            .map { try place($0, isDirectory: true) }
        let files = try plan.files.map { try place($0.relative, isDirectory: false) }
        return LocalLayout(directories: directories, files: files)
    }

    func setTransferBytes(_ id: UUID, _ bytes: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].record(bytes: bytes)
    }

    /// Carried incrementally — re-summing the map each tick would be quadratic over the upload.
    private func setFolderFileBytes(_ id: UUID, index: Int, bytes: Int64) {
        // No row or no map means the transfer was cancelled: a late callback must not resurrect an entry or count against a settled row.
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }),
              sftpFolderBytes[id] != nil else { return }
        let previous = sftpFolderBytes[id, default: [:]].updateValue(bytes, forKey: index) ?? 0
        sftpTransfers[i].record(bytes: sftpTransfers[i].bytes + bytes - previous)
    }

    func setTransferResumeOffset(_ id: UUID, _ offset: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].noteResume(from: offset)
    }

    /// Folder streams call this per skipped file or skipped tail, so the aggregate offset
    /// builds up as the walk discovers what the far end already holds.
    func addTransferResumed(_ id: UUID, _ skipped: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].addResumed(skipped)
    }

    func setTransferTotal(_ id: UUID, _ total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].total = total
    }

    func setTransferProgress(_ id: UUID, bytes: Int64, total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        if total > 0 { sftpTransfers[i].total = total }
        sftpTransfers[i].record(bytes: bytes)
    }

    func settleTransfer(_ id: UUID, _ state: SFTPTransfer.State) {
        sftpTransferTasks[id] = nil
        sftpFolderBytes[id] = nil
        sftpPauseIntents.remove(id)
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        // Snapping to the total is honest only because the shim fails a transfer that ended short.
        if state == .finished { sftpTransfers[i].bytes = max(sftpTransfers[i].bytes, sftpTransfers[i].total) }
        sftpTransfers[i].speed = 0
        sftpTransfers[i].state = state
        // Stops the inspector's elapsed clock; a resume clears it again via `resetProgress`.
        sftpTransfers[i].endedAt = Date()
    }

    func settleTransfer(_ id: UUID, error: Error) {
        if let e = error as? SFTPError {
            // The same abort signal serves both gestures; the recorded intent says which one it was.
            settleTransfer(id, e.kind == .aborted
                           ? (sftpPauseIntents.contains(id) ? .paused : .cancelled)
                           : .failed(e.message))
        } else {
            settleTransfer(id, .failed(error.localizedDescription))
        }
    }

    func bumpMutation() { sftpMutationTick &+= 1 }

    /// `nonisolated`: folder streams consult sizes off the main actor when resuming.
    nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

private struct PlannedUpload {
    let url: URL
    let isDirectory: Bool
    let name: String
    var resuming: Bool = false
}

struct SFTPUploadConflictRequest: Identifiable {
    let id = UUID()
    let connection: SFTPConnection
    let remoteDir: String
    let existing: Set<String>
    let free: [Item]
    var colliding: [Item]

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let isDirectory: Bool
        var name: String { url.lastPathComponent }
    }

    enum Policy: String, CaseIterable, Identifiable {
        case overwrite = "Overwrite"
        /// Continue an interrupted upload of the same item: bytes the server already
        /// holds are kept (whole matching files inside a folder are skipped), and only
        /// the missing tail is sent. Falls back to a full overwrite when the remote
        /// copy can't be a prefix of the local one.
        case resume = "Resume"
        case rename = "Rename"
        case skip = "Skip"
        var id: String { rawValue }
    }
}

private struct FolderScan: Sendable {
    struct File: Sendable { let url: URL; let rel: [String]; let size: Int64 }
    var files: [File] = []
    var dirs: [[String]] = []
    var total: Int64 = 0
    var enumerationFailed = false
    var unreadable: [String] = []

    init(scanning root: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let rootCount = root.pathComponents.count
        let failures = ScanFailureBox()
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { url, _ in failures.add(url.lastPathComponent); return true }
        ) else {
            enumerationFailed = true
            return
        }
        for case let url as URL in en {
            let rel = Array(url.pathComponents.dropFirst(rootCount))
            // An unclassifiable entry matches neither branch below; dropping it silently sends a partial tree and calls it finished.
            guard let vals = try? url.resourceValues(forKeys: keys) else {
                failures.add(url.lastPathComponent)
                continue
            }
            if vals.isDirectory == true {
                dirs.append(rel)
            } else if vals.isRegularFile == true {
                let size = Int64(vals.fileSize ?? 0)
                files.append(File(url: url, rel: rel, size: size))
                total += size
            }
        }
        unreadable = failures.names
    }
}

/// `FileManager`'s `errorHandler` escapes and runs on the enumerating thread, so it needs a locked reference box, not a captured local.
private final class ScanFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(name)
    }
    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Rate-limits progress hops to ~10/sec: libssh2 reports every 256 KB and unthrottled hops queue unbounded; `isFinal` always passes.
final class ProgressCoalescer: @unchecked Sendable {
    private let minInterval: Double
    private let lock = NSLock()
    private var lastEmit = 0.0

    init(minInterval: Double = 0.1) { self.minInterval = minInterval }

    func shouldEmit(isFinal: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if isFinal || now - lastEmit >= minInterval {
            lastEmit = now
            return true
        }
        return false
    }
}
