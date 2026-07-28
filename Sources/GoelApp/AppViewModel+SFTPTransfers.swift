import Foundation
import GoelCore

/// The app-wide SFTP transfer center. Owned here, not by the browser, so transfers survive
/// closing it; a shared ``CancelFlag`` lets cancel abort the blocking libssh2 thread.
@MainActor
extension AppViewModel {

    // MARK: Public entry points

    /// Upload local files/folders into `remoteDir`. Detects name collisions against the
    /// current listing first, raising the overwrite prompt and deferring if any exist.
    func startUpload(items: [URL], toRemoteDir remoteDir: String, on connection: SFTPConnection) {
        guard !items.isEmpty else { return }
        // No client pre-check: `prepareUpload` resolves one itself and reports the failure, and
        // resolving twice would prompt for Keychain access twice for a single drop.
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
        // User-initiated, so report why nothing happened. Resolved here and handed to
        // `runDownload`, so one download means one Keychain read rather than two.
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        // The entry name is server-supplied: sanitize to one safe component so it can't steer
        // the local path, then confirm the join stays inside the chosen folder.
        let safeName = PathSafety.sanitizedName(entry.name)
        // `downloadToFile` truncate-creates, so an existing local file would be destroyed
        // silently. Pick a free "name (n).ext"; without a listing, refuse rather than guess.
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: localDir.path) else {
            toastNow("Couldn’t read “\(localDir.lastPathComponent)”, so “\(entry.name)” wasn’t downloaded.")
            return
        }
        var existingNames = Set(listed)
        // Queued downloads haven't created their files yet, and every dotfile sanitizes to
        // "download" — so reserve names already heading for this folder, as the upload side does.
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
                                    // A folder's listed size is its inode's, not its contents'; the real total lands
                                    // once the tree has been walked.
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

    /// Ask before cancelling an in-flight transfer, then cancel + remove it. Wired to every
    /// cancel button so a stray click can't silently abort a large transfer.
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

    /// Abort immediately: signal the libssh2 thread via ``CancelFlag``, cancel the Task, and
    /// drop the row now. The late `settleTransfer` is a no-op because the row is already gone.
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

    /// Re-run a failed/cancelled transfer in place. Not a free replay: the destination has
    /// moved on, and `downloadToFile` truncate-creates, so the first attempt's checks run again.
    func retrySFTPTransfer(_ id: UUID) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }), !sftpTransfers[i].isActive else { return }
        let t = sftpTransfers[i]
        guard let connection = server(t.connectionID) else { toastNow("That server no longer exists."); return }
        // Resolve before flipping the row to .running: a refused Keychain read must leave the
        // row failed with a reason, not "running" against a client that was never built.
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

    /// The local path a retried download may write to: its own destination if still free, a
    /// uniqued sibling if claimed, or nil if the folder can't be read (then the row fails).
    private func retriedDownloadDestination(id: UUID, current: URL) -> URL? {
        let directory = current.deletingLastPathComponent()
        var listing = DirectoryListing.unavailable
        if let listed = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var taken = Set(listed)
            // Every *other* download heading for this folder has reserved its name. This row is
            // excluded: it may keep the name it already holds.
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

    /// Whether a retried upload may still write to its remote target. An existing *file* is
    /// expected; an unreadable parent, or a target that is now a directory, is not.
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
        // Classify every item before the client is resolved, so an unsendable batch raises no
        // Keychain prompt. An unreadable stat must not default to "file" — upload truncate-creates.
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

        // A directory we couldn't read is not an empty one. Treating it as empty reads as "no
        // conflicts" and authorises TRUNC over files nobody was asked about, so send nothing.
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

    /// Takes an already-resolved `client`: the Keychain can prompt on every read, so a
    /// 20-file drop would raise 20 prompts. One resolution per user action, reused.
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
                    // Bound inside this callback, not the Task: the capture list makes `self` a var and
                    // older toolchains reject reading one from concurrent code.
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

    /// How many files a folder upload sends at once. Each stream holds its own libssh2
    /// session on its own thread, reused per file, so small files move without re-handshaking.
    private static let maxParallelUploads = 4

    /// Recreate a local folder tree on the server and upload its files, several at a time,
    /// keeping the row's byte counters as a running total across the subtree.
    private func uploadFolder(id: UUID, client: SFTPClient, root: URL,
                              remoteRoot: String, cap: Int64, cancel: CancelFlag) async throws {
        // Walk the tree off the main actor so a large folder doesn't hitch the UI.
        let scan = await Task.detached { FolderScan(scanning: root) }.value
        // A failed or partially-classified walk would otherwise settle as a finished upload of
        // an empty tree — failure reported as success. Refuse before anything is sent.
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

        // Directories shallowest → deepest so every file's parent exists. `makeDirectory` tolerates
        // an existing one but still raises denied/quota/name-taken, which a blanket `try?` swallowed.
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

        // `parallel` long-lived workers pulling off a shared cursor: each worker owns one
        // connection for its whole life, so a submit-window would queue two files on one thread.
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
                    // Read the capture into an immutable local once — reading a capture-list var inside a
                    // @Sendable closure is an error in Swift 6. Not unwrapped: a dead view model skips progress, not the upload.
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
                        // Pin this file's contribution to its full size on completion so the aggregate lands
                        // exactly on the total even if the last tick arrived just before EOF.
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
        // `downloadToFile` truncate-creates up front, so any non-success outcome (cancel, stall,
        // disk-full, remote gone) leaves a partial file to clean up — not just on cancel.
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
        // A failed folder download leaves a partial tree, exactly as a failed file leaves a
        // partial file — both are removed rather than left looking finished.
        if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }

    /// Recreate a remote folder tree locally and download its files several at a time — the
    /// mirror of `uploadFolder`, including per-stream connections and aggregate byte counting.
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

        // Sanitising is lossy (every dotfile collapses to "download"), so distinct remote names
        // collide and parallel streams would truncate each other. Resolve distinct paths up front.
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

    /// Map a remote tree onto distinct local paths. Names are untrusted and sanitising is
    /// lossy, so each directory tracks claimed names and a collision takes a "name (2)" sibling.
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

    /// Record one file's progress in a parallel folder upload and report the summed aggregate.
    /// Carried incrementally — re-summing the map each tick would be quadratic over the upload.
    private func setFolderFileBytes(_ id: UUID, index: Int, bytes: Int64) {
        // No row or no map means the transfer was cancelled and both were dropped; a late
        // callback must not resurrect an entry or count against a settled row.
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
        // Snapping to the total on success is honest only because the shim now fails a transfer
        // that ended short — `.finished` means every byte moved.
        if state == .finished { sftpTransfers[i].bytes = max(sftpTransfers[i].bytes, sftpTransfers[i].total) }
        // A settled transfer contributes no throughput to the status-bar / menu-bar
        // totals or the sidebar indicator.
        sftpTransfers[i].speed = 0
        sftpTransfers[i].state = state
    }

    /// Settle a transfer that threw: an explicit abort is a user cancel, an `SFTPError`
    /// carries its own message, anything else falls back to the system description.
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

/// A pending overwrite prompt for one upload batch, resolved by ``SFTPUploadConflictSheet``.
/// Carries the non-colliding items so they ride along once the user decides.
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

/// A recursive local-folder walk computed off the main actor: the files to send (with
/// sizes + server-relative components) and the subdirectories to recreate.
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
            // An unclassifiable entry matched neither branch below and was silently dropped, so the
            // upload sent a partial tree and called it finished. Record it instead.
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

/// Collects names a folder walk couldn't read. `FileManager`'s `errorHandler` escapes and
/// runs on the enumerating thread, so it needs a locked reference box, not a captured local.
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

/// Rate-limits progress → UI hops to ~10/sec for one transfer stream: libssh2 reports every
/// 256 KB, and unthrottled hops queue unbounded. `isFinal` always passes so rows land on 100%.
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
