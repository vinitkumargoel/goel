import Foundation
import GoelCore

/// The app-wide SFTP transfer center.
///
/// Uploads (files *and* folders, recursively) and the browser's "Download to…"
/// downloads are owned here rather than by the per-browser `SFTPBrowserModel`,
/// so a transfer keeps running — and stays visible and cancellable — after the
/// user closes or switches the server browser. Each transfer runs as an
/// unstructured `Task` retained in ``AppViewModel/sftpTransferTasks`` with a
/// shared ``CancelFlag`` the libssh2 progress callback observes, so cancelling
/// actually aborts the blocking transfer thread (not just the wrapping Task).
///
/// One ``SFTPTransfer`` row represents one top-level picked/dropped item; a
/// folder aggregates its whole subtree into that single row's byte counters.
@MainActor
extension AppViewModel {

    // MARK: Public entry points

    /// Upload local files/folders into `remoteDir` on `connection`. Detects
    /// name collisions against the current listing first; if any exist, raises
    /// the overwrite prompt (``sftpUploadConflicts``) and defers the transfers
    /// until it's resolved, otherwise starts them immediately.
    func startUpload(items: [URL], toRemoteDir remoteDir: String, on connection: SFTPConnection) {
        guard !items.isEmpty else { return }
        // No client pre-check here: `prepareUpload` resolves one itself and
        // reports the failure, and resolving twice would prompt for Keychain
        // access twice for a single drop.
        Task { await self.prepareUpload(items: items, remoteDir: remoteDir, connection: connection) }
    }

    /// Resolve the overwrite prompt: skip / rename / overwrite each colliding
    /// item per the user's choice, then launch the whole batch.
    func resolveUploadConflicts(_ request: SFTPUploadConflictRequest,
                                decisions: [UUID: SFTPUploadConflictRequest.Policy]) {
        sftpUploadConflicts = nil
        // Renamed uploads must dodge both the existing remote names *and* the
        // names of the free items in this same batch.
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
            case .rename:
                let unique = SFTPBrowserPaths.uniqueName(item.name, existing: taken)
                taken.insert(unique)
                plan.append(PlannedUpload(url: item.url, isDirectory: item.isDirectory, name: unique))
            }
        }
        // Every colliding item skipped and nothing free = nothing to do; don't
        // resolve (and therefore don't prompt for Keychain access) for no work.
        guard !plan.isEmpty else { return }
        guard let client = sftpClientReportingFailure(for: request.connection) else { return }
        launchUploads(connection: request.connection, remoteDir: request.remoteDir,
                      plan: plan, client: client)
    }

    /// Download a single remote file to a local folder (browser "Download to…").
    func startDownload(_ entry: SFTPEntry, from connection: SFTPConnection,
                       remoteDir: String, toLocalDir localDir: URL) {
        // User-initiated, so report why nothing happened rather than returning
        // mute — a refused Keychain prompt otherwise looks like a dead menu item.
        //
        // Resolved here and handed to `runDownload`, so one download = one
        // Keychain read rather than one to check and another to transfer.
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        // The entry name is server-supplied; sanitize to one safe component so it
        // can't steer the *local* path (../ traversal / absolute paths), then
        // confirm the join stays inside the chosen folder.
        let safeName = PathSafety.sanitizedName(entry.name)
        // `downloadToFile` truncate-creates its destination, so writing onto an
        // existing local file would silently destroy it — there's no download
        // conflict prompt. Pick a non-colliding "name (n).ext" instead (matching
        // the upload rename policy). Without a listing there is no way to tell a
        // free name from one that would destroy an existing file, so refuse.
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: localDir.path) else {
            toastNow("Couldn’t read “\(localDir.lastPathComponent)”, so “\(entry.name)” wasn’t downloaded.")
            return
        }
        var existingNames = Set(listed)
        // Downloads queued a moment ago haven't created their files yet, so the
        // directory listing alone would hand two remote entries the same local
        // name — every dotfile sanitizes to the literal "download", so a
        // multi-select of ".bashrc" and ".zshrc" would have the second truncate
        // the first. Reserve what is already heading for this folder, the same
        // in-batch bookkeeping the upload side does. `sftpTransfers` is appended
        // to synchronously below, so on the main actor this is race-free.
        existingNames.formUnion(sftpTransfers.lazy
            .filter { $0.direction == .download && $0.isActive
                && $0.localURL?.deletingLastPathComponent().standardizedFileURL == localDir.standardizedFileURL }
            .compactMap { $0.localURL?.lastPathComponent })
        let localName = SFTPBrowserPaths.uniqueName(safeName, existing: existingNames)
        let destination = localDir.appendingPathComponent(localName)
        guard SFTPBrowserModel.isContained(destination, in: localDir) else {
            toastNow("Refusing to write “\(entry.name)” outside the chosen folder."); return
        }
        let remoteSource = SFTPBrowserPaths.join(remoteDir, entry.name)
        let cancel = CancelFlag()
        let transfer = SFTPTransfer(connectionID: connection.id, name: localName, direction: .download,
                                    isDirectory: entry.isDirectory, localURL: destination,
                                    remotePath: remoteSource,
                                    // A folder's listed size is its inode's, not
                                    // its contents'; the real total lands once the
                                    // tree has been walked.
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

    // MARK: Cancel / retry / clear

    /// Ask before cancelling an in-flight transfer, then cancel + remove it.
    /// Wired to every cancel button (browser strip, status bar, menu bar) so a
    /// stray click can't silently abort a large transfer.
    func requestCancelSFTPTransfer(_ id: UUID) {
        guard let t = sftpTransfers.first(where: { $0.id == id }) else { return }
        // An already-settled row (finished/failed/cancelled) just gets dropped —
        // no need to ask.
        guard t.isActive else { cancelSFTPTransfer(id); return }
        let verb = t.cancelNoun
        requestConfirm(
            title: "Cancel this \(verb)?",
            message: "“\(t.name)” will stop transferring and be removed from the list.",
            confirmTitle: "Stop Transfer",
            destructive: true
        ) { [weak self] in self?.cancelSFTPTransfer(id) }
    }

    /// Abort an in-flight transfer *immediately*: signal the libssh2 thread to
    /// stop (via the shared ``CancelFlag``), cancel the wrapping Task, and drop
    /// the row from the list right away — the UI never waits for the transfer
    /// thread to notice the flag on its next progress tick. The background task
    /// still unwinds and cleans up any partial local file; its late
    /// `settleTransfer` is a no-op because the row is already gone.
    func cancelSFTPTransfer(_ id: UUID) {
        if let entry = sftpTransferTasks[id] {
            entry.cancel.cancel()
            entry.task.cancel()
        }
        sftpTransferTasks[id] = nil
        sftpFolderBytes[id] = nil
        sftpRemoteCopyPlans[id] = nil
        sftpTransfers.removeAll { $0.id == id }
        toastNow("Transfer cancelled")
    }

    /// Re-run a failed/cancelled transfer in place (same row, reset counters).
    ///
    /// A retry is not a free replay of the first attempt's authorisation: the
    /// destination has moved on since. A failed download deletes its partial file
    /// and its row stops reserving that name, so by the time Retry is clicked the
    /// path this row still points at may belong to a *different*, completed
    /// transfer — and `downloadToFile` truncate-creates, so replaying blind would
    /// destroy a file nobody was asked about. That is not exotic either: every
    /// dotfile sanitizes to the same literal "download", so two remote dotfiles
    /// into one folder collide by default.
    ///
    /// So the checks that guarded the first attempt run again here, and a
    /// destination that cannot be checked settles the row as failed rather than
    /// being written to on a guess.
    func retrySFTPTransfer(_ id: UUID) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }), !sftpTransfers[i].isActive else { return }
        let t = sftpTransfers[i]
        guard let connection = server(t.connectionID) else { toastNow("That server no longer exists."); return }
        // Resolve before flipping the row to .running: if the Keychain read is
        // refused, the row must stay failed with the reason toasted, not sit
        // "running" against a client that was never built.
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        // Marked running *before* the preflight below, so this row reserves its
        // destination against any transfer started while the preflight is in flight.
        sftpTransfers[i].state = .running
        sftpTransfers[i].resetProgress()
        let cancel = CancelFlag()
        let task = Task { [weak self] in
            guard let self else { return }
            // Both branches need the row's local endpoint; a row that somehow
            // lost it can't be replayed against a guessed path.
            guard let localURL = t.localURL else {
                self.settleTransfer(id, .failed("This transfer can’t be retried."))
                return
            }
            switch t.direction {
            case .upload:
                guard await self.retriedUploadIsStillAuthorised(id: id, client: client,
                                                                remoteTarget: t.remotePath,
                                                                isDir: t.isDirectory) else { return }
                await self.runUpload(id: id, client: client, localURL: localURL,
                                     isDir: t.isDirectory, remoteTarget: t.remotePath, cancel: cancel)
            case .download:
                guard let destination = self.retriedDownloadDestination(id: id, current: localURL)
                else { return }
                await self.runDownload(id: id, client: client,
                                       remoteSource: t.remotePath, destination: destination,
                                       cancel: cancel, isDirectory: t.isDirectory)
            case .remoteCopy:
                await self.runRemoteCopy(id: id, cancel: cancel)
            }
        }
        sftpTransferTasks[id] = (task, cancel)
    }

    /// The local path a retried download may write to: the row's own destination
    /// when it is still free, a uniqued sibling when something else has claimed it
    /// since, or nil when the folder can't be read — in which case the row is
    /// settled as failed rather than left running.
    ///
    /// Renaming rather than truncating is the same policy the upload side applies
    /// to a collision, and the row is updated so the list names the file that
    /// actually appears on disk.
    private func retriedDownloadDestination(id: UUID, current: URL) -> URL? {
        let directory = current.deletingLastPathComponent()
        var listing = DirectoryListing.unavailable
        if let listed = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var taken = Set(listed)
            // Every *other* download heading for this folder has reserved its name —
            // the same in-batch bookkeeping `startDownload` does. This row is
            // excluded: it is allowed to keep the name it already holds.
            taken.formUnion(sftpTransfers.lazy
                .filter { $0.id != id && $0.direction == .download && $0.isActive
                    && $0.localURL?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }
                .compactMap { $0.localURL?.lastPathComponent })
            listing = .names(taken)
        }
        guard let name = SFTPOverwritePlan.retryName(current.lastPathComponent, against: listing) else {
            settleTransfer(id, .failed("Couldn’t read “\(directory.lastPathComponent)” — nothing was downloaded."))
            return nil
        }
        guard name != current.lastPathComponent else { return current }
        let destination = directory.appendingPathComponent(name)
        guard SFTPBrowserModel.isContained(destination, in: directory) else {
            settleTransfer(id, .failed("Refusing to write “\(name)” outside the chosen folder."))
            return nil
        }
        if let i = sftpTransfers.firstIndex(where: { $0.id == id }) {
            sftpTransfers[i].localURL = destination
            sftpTransfers[i].name = name
        }
        return destination
    }

    /// Whether a retried upload may still write to its remote target.
    ///
    /// The user already authorised this exact path (either it was free, or they
    /// answered the overwrite prompt), and a first attempt that failed part-way has
    /// itself left a partial file there — so an existing *file* is expected and
    /// overwriting it is what Retry means. What must not happen is the two failure
    /// modes the first attempt was guarded against: a parent directory that can no
    /// longer be listed (nothing may be sent on a guess), and a single-file target
    /// that is now a *directory*, which `client.upload` would truncate-create
    /// against. A folder upload legitimately targets a directory, so it only needs
    /// the listing to succeed.
    private func retriedUploadIsStillAuthorised(id: UUID, client: SFTPClient,
                                                remoteTarget: String, isDir: Bool) async -> Bool {
        let parent = SFTPBrowserPaths.parent(of: remoteTarget)
        let place = parent == "." ? "Home" : parent
        let entries: [SFTPEntry]
        do {
            entries = try await client.list(parent)
        } catch let e as SFTPError {
            settleTransfer(id, .failed("Couldn’t check what’s already in \(place) — nothing was uploaded. \(e.message)"))
            return false
        } catch {
            settleTransfer(id, .failed("Couldn’t check what’s already in \(place) — nothing was uploaded."))
            return false
        }
        let name = (remoteTarget as NSString).lastPathComponent
        if !isDir, entries.contains(where: { $0.name == name && $0.isDirectory }) {
            settleTransfer(id, .failed("“\(name)” is a folder on the server now — nothing was uploaded."))
            return false
        }
        return true
    }

    /// Drop every settled (finished/failed/cancelled) transfer from the list.
    func clearFinishedSFTPTransfers() {
        let before = sftpTransfers.count
        let dropped = Set(sftpTransfers.lazy.filter { !$0.isActive }.map(\.id))
        sftpTransfers.removeAll { !$0.isActive }
        // A dropped row can never be retried, so its replay plan is dead weight.
        for id in dropped { sftpRemoteCopyPlans[id] = nil }
        if sftpTransfers.count != before { toastNow("Cleared finished transfers") }
    }

    /// The active transfers for one server, for the browser's own strip.
    func sftpTransfers(for connectionID: UUID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.connectionID == connectionID }
    }

    // MARK: Preparation

    private func prepareUpload(items: [URL], remoteDir: String, connection: SFTPConnection) async {
        // Classify every item before anything else — including before the client
        // is resolved, so a batch that can't be sent never raises a Keychain
        // prompt. A stat we can't read must not default to "file": the item would
        // be routed to `client.upload`, which truncate-creates the remote name and
        // only then fails on the directory, after destroying whatever was there.
        var isDirectories: [Bool] = []
        for url in items {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = values.isDirectory else {
                toastNow("Couldn’t read “\(url.lastPathComponent)” — nothing was uploaded.")
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

        // A directory we couldn't read is not an empty directory. Treating it as
        // one reads as "no conflicts", skips the overwrite prompt, and authorises
        // `LIBSSH2_FXF_TRUNC` over files the user was never asked about — so
        // nothing is sent.
        guard case .names(let existing) = listing,
              let split = SFTPOverwritePlan.split(names: items.map(\.lastPathComponent),
                                                  against: listing) else {
            let place = remoteDir == "." ? "Home" : remoteDir
            toastNow("Couldn’t check what’s already in \(place) — nothing was uploaded."
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
            let url = item.url, isDir = item.isDirectory
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runUpload(id: id, client: client, localURL: url,
                                     isDir: isDir, remoteTarget: remoteTarget, cancel: cancel)
            }
            sftpTransferTasks[id] = (task, cancel)
        }
    }

    // MARK: Transfer execution

    /// Takes an already-resolved `client` rather than resolving its own: the
    /// Keychain can prompt on every read, so a 20-file drop would otherwise
    /// raise 20 prompts. One resolution per user action, reused for the batch.
    private func runUpload(id: UUID, client baseClient: SFTPClient, localURL: URL, isDir: Bool,
                           remoteTarget: String, cancel: CancelFlag) async {
        let cap = settings.effectiveProfile.maxUploadBytesPerSec
        // One connection for this whole job, so a 500-file folder pays one
        // handshake rather than 500. Released below on every exit path.
        let client = baseClient.forTransfer(id)
        do {
            if isDir {
                try await uploadFolder(id: id, client: client, root: localURL,
                                       remoteRoot: remoteTarget, cap: cap, cancel: cancel)
            } else {
                setTransferTotal(id, Self.fileSize(localURL))
                let coalescer = ProgressCoalescer()
                try await client.upload(localURL: localURL, remote: remoteTarget, maxBytesPerSecond: cap,
                                        shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                    guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                    // Bound inside this callback, not the Task: the capture list
                    // above makes `self` a var and older toolchains reject
                    // reading one from concurrent code. Dropping the update when
                    // the model is gone is what `self?.` did anyway.
                    guard let self else { return }
                    Task { @MainActor in self.setTransferBytes(id, sofar) }
                }
            }
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        await client.finishTransfer(id)
        // Any outcome may have created/partially-written remote files
        // (libssh2 opens with CREAT), so refresh a browser on this server.
        bumpMutation()
    }

    /// How many files a single folder upload sends at once. Each stream holds its
    /// own libssh2 session on its own thread — reused across every file that
    /// stream handles — so several small files (latency-bound on their open/close
    /// round-trips) move in parallel without re-handshaking per file.
    private static let maxParallelUploads = 4

    /// Recreate a local folder tree on the server and upload its files — several
    /// at a time — keeping the row's byte counters as a running total across the
    /// whole subtree.
    private func uploadFolder(id: UUID, client: SFTPClient, root: URL,
                              remoteRoot: String, cap: Int64, cancel: CancelFlag) async throws {
        // Walk the tree off the main actor so a large folder doesn't hitch the UI.
        let scan = await Task.detached { FolderScan(scanning: root) }.value
        // A walk that failed, or that skipped entries it couldn't classify, would
        // otherwise settle as a finished upload of an empty or partial tree — a
        // failure reported to the user as success. Refuse before anything is sent.
        guard !scan.enumerationFailed else {
            throw SFTPError(kind: .io, message: "Couldn’t read “\(root.lastPathComponent)” — nothing was uploaded.")
        }
        if let first = scan.unreadable.first {
            let others = scan.unreadable.count - 1
            throw SFTPError(kind: .io,
                            message: "Couldn’t read “\(first)”\(others > 0 ? " and \(others) more item\(others == 1 ? "" : "s")" : "") inside “\(root.lastPathComponent)” — nothing was uploaded.")
        }
        setTransferTotal(id, scan.total)
        sftpFolderBytes[id] = [:]

        // Directories first (shallowest → deepest) so every file's parent exists.
        // `makeDirectory` tolerates one that already exists — merging into a folder
        // is normal — but still raises permission-denied, quota, and
        // name-taken-by-a-file, which a blanket `try?` here used to swallow: an
        // upload of a tree of empty folders would then report success having
        // created nothing at all.
        try await SFTPRelay.makeDirectory(remoteRoot, on: client)
        for rel in scan.dirs.sorted(by: { $0.count < $1.count }) {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
            try await SFTPRelay.makeDirectory(rel.reduce(remoteRoot, SFTPBrowserPaths.join),
                                              on: client)
        }

        let files = scan.files
        guard !files.isEmpty else { return }
        let parallel = min(Self.maxParallelUploads, files.count)
        // Split the global upload cap across the concurrent streams so N parallel
        // transfers still respect the one profile limit (0 = unlimited).
        let perStreamCap = cap > 0 ? max(1, cap / Int64(parallel)) : 0

        // `parallel` long-lived workers, each pulling the next file off a shared
        // cursor. Workers rather than a bounded submit-window because each worker
        // *owns* one connection for its whole life: a window would let a newly
        // submitted task land on a slot whose predecessor was still running, and
        // the two would then queue behind each other on one thread. A throw (I/O
        // error or cancel) cancels the group.
        let cursor = UploadCursor()
        let streamIDs = (0..<parallel).map { _ in UUID() }
        defer {
            // Detached: `defer` cannot await, and these must be returned to the
            // pool even when the group throws.
            let ids = streamIDs
            Task.detached { for streamID in ids { await client.finishTransfer(streamID) } }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for streamID in streamIDs {
                let stream = client.forTransfer(streamID)
                group.addTask { [weak self] in
                    // Read the capture into an immutable local once. The progress
                    // closure below is @Sendable, and reading a capture-list var
                    // from inside one is an error in the Swift 6 language mode —
                    // binding here is what the two uses further down rely on.
                    //
                    // Deliberately not unwrapped: a view model that has gone away
                    // must skip the progress reporting, not the upload.
                    let model = self
                    while let index = await cursor.next(limit: files.count) {
                        if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
                        let file = files[index]
                        let remoteFile = file.rel.reduce(remoteRoot, SFTPBrowserPaths.join)
                        let coalescer = ProgressCoalescer()
                        try await stream.upload(localURL: file.url, remote: remoteFile,
                                                maxBytesPerSecond: perStreamCap,
                                                shouldContinue: { !cancel.isCancelled }) { sofar, total in
                            guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                            guard let model else { return }
                            Task { @MainActor in model.setFolderFileBytes(id, index: index, bytes: sofar) }
                        }
                        // Pin this file's contribution to its full size on completion
                        // so the aggregate lands exactly on the total even if the
                        // final progress tick arrived just before EOF.
                        if let model {
                            await MainActor.run { model.setFolderFileBytes(id, index: index, bytes: file.size) }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Hands out file indices to the folder-upload workers, one at a time.
    private actor UploadCursor {
        private var index = 0
        func next(limit: Int) -> Int? {
            guard index < limit else { return nil }
            defer { index += 1 }
            return index
        }
    }

    /// Takes an already-resolved `client` — see ``runUpload(id:client:localURL:isDir:remoteTarget:cancel:)``.
    private func runDownload(id: UUID, client baseClient: SFTPClient, remoteSource: String,
                             destination: URL, cancel: CancelFlag, isDirectory: Bool = false) async {
        let cap = settings.effectiveProfile.maxDownloadBytesPerSec
        // This job's own connection, so a download never queues behind a folder
        // listing (and vice versa). Released on every exit path below.
        let client = baseClient.forTransfer(id)
        // `downloadToFile` truncate-creates the destination up front, so any
        // non-success outcome (cancel, network stall, disk-full, remote gone)
        // leaves a partial file that must be cleaned up — not just on cancel.
        var succeeded = false
        do {
            if isDirectory {
                try await downloadFolder(id: id, client: client, remoteRoot: remoteSource,
                                         localRoot: destination, cap: cap, cancel: cancel)
            } else {
                let coalescer = ProgressCoalescer()
                try await client.downloadToFile(remote: remoteSource, localURL: destination,
                                                maxBytesPerSecond: cap,
                                                shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                    guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                    guard let self else { return }
                    Task { @MainActor in self.setTransferProgress(id, bytes: sofar, total: total) }
                }
            }
            succeeded = true
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        await client.finishTransfer(id)
        // A failed folder download leaves a partial tree, exactly as a failed file
        // leaves a partial file — both are removed rather than left to look
        // finished.
        if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }

    /// Recreate a remote folder tree locally and download its files, several at a
    /// time — the mirror of ``uploadFolder(id:client:root:remoteRoot:cap:cancel:)``,
    /// including its per-stream connections and its aggregate byte counting.
    private func downloadFolder(id: UUID, client: SFTPClient, remoteRoot: String,
                                localRoot: URL, cap: Int64, cancel: CancelFlag) async throws {
        // Walked on the background connection so a large tree doesn't hold the
        // job's own connection while it enumerates.
        let plan = try await SFTPRelay.walk(client.onBackground(), root: remoteRoot,
                                            shouldContinue: { !cancel.isCancelled })
        // A walk that had to skip an entry would silently download a partial tree
        // and then report it as complete. Refuse instead, matching the local scan.
        try SFTPRelay.requireComplete(plan)
        setTransferTotal(id, plan.files.reduce(0) { $0 + $1.size })
        sftpFolderBytes[id] = [:]

        // Every remote name is sanitised before it touches the disk, and
        // sanitising is lossy: every dotfile collapses to the literal "download",
        // and long names are clamped. So ".alpha/x" and ".beta/x" both want the
        // same local path, and four parallel streams would truncate each other's
        // files with no error at all. Resolve the whole tree to distinct local
        // paths up front, exactly as the single-file download reserves names.
        let layout = try Self.localLayout(for: plan, under: localRoot)

        // Directories first, shallowest first, so every file has a parent.
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        for url in layout.directories {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
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
                        if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
                        let file = files[index]
                        let local = layout.files[index]
                        let remote = file.relative.reduce(remoteRoot, SFTPBrowserPaths.join)
                        let coalescer = ProgressCoalescer()
                        try await stream.downloadToFile(remote: remote, localURL: local,
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

    /// Where each item of a remote tree lands locally.
    struct LocalLayout {
        /// Directories to create, shallowest first.
        let directories: [URL]
        /// One URL per file in the plan, in the plan's own order.
        let files: [URL]
    }

    /// Map a remote tree onto distinct local paths.
    ///
    /// Two things make this more than a join. Server-supplied names are untrusted,
    /// so each component is rejected outright if it carries path structure and
    /// sanitised otherwise; and sanitising is *lossy* — every dotfile becomes
    /// "download", long names are clamped — so distinct remote names routinely
    /// collide. Each directory keeps a record of the names already claimed inside
    /// it, and a collision takes a "name (2)" sibling rather than silently
    /// overwriting a different remote file.
    nonisolated static func localLayout(for plan: SFTPRelay.TreePlan,
                                        under root: URL) throws -> LocalLayout {
        // Remote relative path -> resolved local URL, so a file's parent is found
        // at the name its directory actually took.
        var resolved: [[String]: URL] = [[]: root]
        // Local directory path -> names already used inside it.
        var claimed: [String: Set<String>] = [:]

        func place(_ relative: [String], isDirectory: Bool) throws -> URL {
            let parentPath = Array(relative.dropLast())
            guard let name = relative.last, let parent = resolved[parentPath] else {
                throw SFTPError(kind: .io, message: "Couldn’t work out where to save “\(relative.joined(separator: "/"))”.")
            }
            guard SFTPBrowserPaths.isSafeChildName(name) else {
                throw SFTPError(kind: .io,
                                message: "The server sent an item named “\(name)”, which Goel won’t write to disk.")
            }
            let key = parent.standardizedFileURL.path
            var taken = claimed[key] ?? []
            let unique = SFTPBrowserPaths.uniqueName(PathSafety.sanitizedName(name), existing: taken)
            taken.insert(unique)
            claimed[key] = taken

            let url = parent.appendingPathComponent(unique)
            // Belt and braces on top of the per-component checks: the final path
            // must still resolve inside the folder the user chose.
            guard PathSafety.isContained(url.path, within: root.path) else {
                throw SFTPError(kind: .io, message: "Refusing to write outside the download folder.")
            }
            if isDirectory { resolved[relative] = url }
            return url
        }

        // Shallowest first, so a directory is always placed before its children
        // need to look up its resolved name.
        let directories = try plan.directories
            .sorted { $0.count < $1.count }
            .map { try place($0, isDirectory: true) }
        let files = try plan.files.map { try place($0.relative, isDirectory: false) }
        return LocalLayout(directories: directories, files: files)
    }

    // MARK: Row bookkeeping (all on the main actor)

    func setTransferBytes(_ id: UUID, _ bytes: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].record(bytes: bytes)
    }

    /// Record one file's progress within a parallel folder upload and report the
    /// summed aggregate as the row's byte count.
    ///
    /// The aggregate is carried *incrementally* — each callback adds only its own
    /// delta to the row's current count — rather than re-summing the map. The map
    /// keeps one entry per file in the subtree (every finished file pins its final
    /// size back into it), so re-summing on every tick would be O(files) main-actor
    /// work per tick, i.e. quadratic over the upload: a 20k-file drop would hitch
    /// the UI progressively worse as it advanced.
    private func setFolderFileBytes(_ id: UUID, index: Int, bytes: Int64) {
        // No row, or no map, means the transfer was cancelled and both were already
        // dropped; a late callback from a still-unwinding stream must not resurrect
        // an entry (nothing would ever clear it) or count against a settled row.
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }),
              sftpFolderBytes[id] != nil else { return }
        let previous = sftpFolderBytes[id, default: [:]].updateValue(bytes, forKey: index) ?? 0
        sftpTransfers[i].record(bytes: sftpTransfers[i].bytes + bytes - previous)
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
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        // Snapping to the total on success is only honest because the shim now
        // fails a transfer that ended short of its known size — `.finished` means
        // every byte moved, so this only closes the gap left by a final progress
        // tick that arrived just before EOF.
        if state == .finished { sftpTransfers[i].bytes = max(sftpTransfers[i].bytes, sftpTransfers[i].total) }
        // A settled transfer contributes no throughput to the status-bar / menu-bar
        // totals or the sidebar indicator.
        sftpTransfers[i].speed = 0
        sftpTransfers[i].state = state
    }

    /// Settle a transfer that threw: an explicit abort is a user cancel, an
    /// `SFTPError` carries its own message, anything else falls back to the
    /// system description.
    func settleTransfer(_ id: UUID, error: Error) {
        if let e = error as? SFTPError {
            settleTransfer(id, e.kind == .aborted ? .cancelled : .failed(e.message))
        } else {
            settleTransfer(id, .failed(error.localizedDescription))
        }
    }

    func bumpMutation() { sftpMutationTick &+= 1 }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

// MARK: - Supporting types

/// One resolved item to upload: the local source, whether it's a directory, and
/// the (possibly renamed) name to give it on the server.
private struct PlannedUpload {
    let url: URL
    let isDirectory: Bool
    let name: String
}

/// A pending overwrite prompt for one upload batch, resolved by
/// ``SFTPUploadConflictSheet``. Carries the free (non-colliding) items so they
/// ride along once the user decides what to do with the colliding ones.
struct SFTPUploadConflictRequest: Identifiable {
    let id = UUID()
    let connection: SFTPConnection
    let remoteDir: String
    /// Names already present in `remoteDir` (so renames avoid a second clash).
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
        case rename = "Rename"
        case skip = "Skip"
        var id: String { rawValue }
    }
}

/// A recursive local-folder walk computed off the main actor: the files to send
/// (with sizes + server-relative path components) and the subdirectories to
/// recreate.
private struct FolderScan: Sendable {
    struct File: Sendable { let url: URL; let rel: [String]; let size: Int64 }
    var files: [File] = []
    var dirs: [[String]] = []
    var total: Int64 = 0
    /// True when the walk could not start at all.
    var enumerationFailed = false
    /// The names the walk could not read or classify. A folder upload must not
    /// report success for a subtree it never actually read, so these abort it.
    var unreadable: [String] = []

    init(scanning root: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let rootCount = root.pathComponents.count
        // `errorHandler` escapes, so the skipped names can't accumulate into a
        // local of this initializer — same shape as ``ReadErrorBox``.
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
            // An unclassifiable entry matched neither branch below and was
            // silently dropped, so the upload sent a partial tree and called it
            // finished. Record it instead.
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

/// Collects the names a folder walk couldn't read. `FileManager`'s
/// `errorHandler` escapes and runs on the enumerating thread, so the failures
/// need a reference box with a lock rather than a captured local.
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

/// Rate-limits progress → UI hops for a single transfer stream.
///
/// libssh2 reports progress on every 256 KB chunk, and each report we forward
/// spawns a `Task { @MainActor }` that mutates a published transfer row. On a
/// fast link — or several parallel folder streams — the transfer thread outruns
/// the main actor, so those hops queue up unbounded: a multi-gigabyte transfer
/// enqueues tens of thousands of jobs (millions across parallel streams) faster
/// than they drain, ballooning resident memory until the transfer ends. Capping
/// the hops to ~10/sec keeps the row just as smooth to the eye while bounding the
/// queue to a handful of jobs at a time. The byte writes and per-chunk
/// cancellation checks are untouched — only the UI notification is throttled.
///
/// `isFinal` always passes so the row lands exactly on 100% rather than freezing
/// a fraction short until the transfer settles. Monotonic `systemUptime` avoids
/// wall-clock jumps, and the lock makes it safe to call from the transfer thread.
final class ProgressCoalescer: @unchecked Sendable {
    private let minInterval: Double
    private let lock = NSLock()
    private var lastEmit = 0.0

    init(minInterval: Double = 0.1) { self.minInterval = minInterval }

    /// True at most once per `minInterval`, but always true when `isFinal`.
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
