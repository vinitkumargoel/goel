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
        guard sftpClient(for: connection) != nil else {
            toastNow("This server is misconfigured."); return
        }
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
        launchUploads(connection: request.connection, remoteDir: request.remoteDir, plan: plan)
    }

    /// Download a single remote file to a local folder (browser "Download to…").
    func startDownload(_ entry: SFTPEntry, from connection: SFTPConnection,
                       remoteDir: String, toLocalDir localDir: URL) {
        guard !entry.isDirectory, sftpClient(for: connection) != nil else { return }
        // The entry name is server-supplied; sanitize to one safe component so it
        // can't steer the *local* path (../ traversal / absolute paths), then
        // confirm the join stays inside the chosen folder.
        let safeName = PathSafety.sanitizedName(entry.name)
        // `downloadToFile` truncate-creates its destination, so writing onto an
        // existing local file would silently destroy it — there's no download
        // conflict prompt. Pick a non-colliding "name (n).ext" instead (matching
        // the upload rename policy). This also stops two different remote dotfiles,
        // which both sanitize to the literal "download", from clobbering each other.
        let existingNames = Set((try? FileManager.default.contentsOfDirectory(atPath: localDir.path)) ?? [])
        let localName = SFTPBrowserPaths.uniqueName(safeName, existing: existingNames)
        let destination = localDir.appendingPathComponent(localName)
        guard SFTPBrowserModel.isContained(destination, in: localDir) else {
            toastNow("Refusing to write “\(entry.name)” outside the chosen folder."); return
        }
        let remoteSource = SFTPBrowserPaths.join(remoteDir, entry.name)
        let cancel = CancelFlag()
        let transfer = SFTPTransfer(connectionID: connection.id, name: localName, direction: .download,
                                    isDirectory: false, localURL: destination, remotePath: remoteSource,
                                    total: entry.size)
        sftpTransfers.append(transfer)
        let id = transfer.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(id: id, connection: connection,
                                   remoteSource: remoteSource, destination: destination, cancel: cancel)
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
        let verb = t.direction == .upload ? "upload" : "download"
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
        sftpTransfers.removeAll { $0.id == id }
        toastNow("Transfer cancelled")
    }

    /// Re-run a failed/cancelled transfer in place (same row, reset counters).
    func retrySFTPTransfer(_ id: UUID) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }), !sftpTransfers[i].isActive else { return }
        let t = sftpTransfers[i]
        guard let connection = server(t.connectionID) else { toastNow("That server no longer exists."); return }
        sftpTransfers[i].state = .running
        sftpTransfers[i].resetProgress()
        let cancel = CancelFlag()
        let task: Task<Void, Never>
        switch t.direction {
        case .upload:
            task = Task { [weak self] in
                guard let self else { return }
                await self.runUpload(id: id, connection: connection, localURL: t.localURL,
                                     isDir: t.isDirectory, remoteTarget: t.remotePath, cancel: cancel)
            }
        case .download:
            task = Task { [weak self] in
                guard let self else { return }
                await self.runDownload(id: id, connection: connection,
                                       remoteSource: t.remotePath, destination: t.localURL, cancel: cancel)
            }
        }
        sftpTransferTasks[id] = (task, cancel)
    }

    /// Drop every settled (finished/failed/cancelled) transfer from the list.
    func clearFinishedSFTPTransfers() {
        let before = sftpTransfers.count
        sftpTransfers.removeAll { !$0.isActive }
        if sftpTransfers.count != before { toastNow("Cleared finished transfers") }
    }

    /// The active transfers for one server, for the browser's own strip.
    func sftpTransfers(for connectionID: UUID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.connectionID == connectionID }
    }

    // MARK: Preparation

    private func prepareUpload(items: [URL], remoteDir: String, connection: SFTPConnection) async {
        guard let client = sftpClient(for: connection) else { return }
        let existing = Set(((try? await client.list(remoteDir)) ?? []).map(\.name))
        var free: [SFTPUploadConflictRequest.Item] = []
        var colliding: [SFTPUploadConflictRequest.Item] = []
        // A name collides if it's already on the server *or* if an earlier item
        // in this same batch already claimed it — otherwise two picked items
        // that share a last path component (e.g. two "photo.jpg" from different
        // folders) would both be "free" and race two writers onto one remote path.
        var taken = existing
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = SFTPUploadConflictRequest.Item(url: url, isDirectory: isDir)
            if taken.contains(url.lastPathComponent) {
                colliding.append(item)
            } else {
                free.append(item)
                taken.insert(url.lastPathComponent)
            }
        }
        if colliding.isEmpty {
            launchUploads(connection: connection, remoteDir: remoteDir,
                          plan: free.map { PlannedUpload(url: $0.url, isDirectory: $0.isDirectory,
                                                         name: $0.url.lastPathComponent) })
        } else {
            sftpUploadConflicts = SFTPUploadConflictRequest(connection: connection, remoteDir: remoteDir,
                                                            existing: existing, free: free, colliding: colliding)
        }
    }

    private func launchUploads(connection: SFTPConnection, remoteDir: String, plan: [PlannedUpload]) {
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
                await self.runUpload(id: id, connection: connection, localURL: url,
                                     isDir: isDir, remoteTarget: remoteTarget, cancel: cancel)
            }
            sftpTransferTasks[id] = (task, cancel)
        }
    }

    // MARK: Transfer execution

    private func runUpload(id: UUID, connection: SFTPConnection, localURL: URL, isDir: Bool,
                           remoteTarget: String, cancel: CancelFlag) async {
        guard let client = sftpClient(for: connection) else {
            settleTransfer(id, .failed("This server is misconfigured.")); return
        }
        let cap = settings.effectiveProfile.maxUploadBytesPerSec
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
                    Task { @MainActor in self?.setTransferBytes(id, sofar) }
                }
            }
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        // Any outcome may have created/partially-written remote files
        // (libssh2 opens with CREAT), so refresh a browser on this server.
        bumpMutation()
    }

    /// How many files a single folder upload sends at once. Each stream is its own
    /// libssh2 session on its own thread, so several small files (latency-bound on
    /// their open/close round-trips) move in parallel instead of one at a time.
    private static let maxParallelUploads = 4

    /// Recreate a local folder tree on the server and upload its files — several
    /// at a time — keeping the row's byte counters as a running total across the
    /// whole subtree.
    private func uploadFolder(id: UUID, client: SFTPClient, root: URL,
                              remoteRoot: String, cap: Int64, cancel: CancelFlag) async throws {
        // Walk the tree off the main actor so a large folder doesn't hitch the UI.
        let scan = await Task.detached { FolderScan(scanning: root) }.value
        setTransferTotal(id, scan.total)
        sftpFolderBytes[id] = [:]

        // Directories first (shallowest → deepest) so every file's parent exists.
        // mkdir on an existing dir errors; ignore it so overwrite/merge works.
        _ = try? await client.mkdir(remoteRoot)
        for rel in scan.dirs.sorted(by: { $0.count < $1.count }) {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
            _ = try? await client.mkdir(rel.reduce(remoteRoot, SFTPBrowserPaths.join))
        }

        let files = scan.files
        guard !files.isEmpty else { return }
        let parallel = min(Self.maxParallelUploads, files.count)
        // Split the global upload cap across the concurrent streams so N parallel
        // transfers still respect the one profile limit (0 = unlimited).
        let perStreamCap = cap > 0 ? max(1, cap / Int64(parallel)) : 0

        // Upload with a bounded window: prime `parallel` files, then start the next
        // as each finishes. A throw (I/O error or cancel) cancels the group.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ index: Int) {
                let file = files[index]
                let remoteFile = file.rel.reduce(remoteRoot, SFTPBrowserPaths.join)
                group.addTask { [weak self] in
                    if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
                    // `[weak self]` binds a *var* (it can go nil at any time), and the
                    // nested progress/completion closures below run concurrently — so
                    // capturing it directly races. Snapshot it once into a `let` that
                    // those closures can capture safely; it lives only as long as this
                    // one file's upload.
                    let vm = self
                    let coalescer = ProgressCoalescer()
                    try await client.upload(localURL: file.url, remote: remoteFile,
                                            maxBytesPerSecond: perStreamCap,
                                            shouldContinue: { !cancel.isCancelled }) { sofar, total in
                        guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                        Task { @MainActor in vm?.setFolderFileBytes(id, index: index, bytes: sofar) }
                    }
                    // Pin this file's contribution to its full size on completion so
                    // the aggregate lands exactly on the total even if the final
                    // progress tick arrived just before EOF.
                    await MainActor.run { vm?.setFolderFileBytes(id, index: index, bytes: file.size) }
                }
            }
            while next < parallel { submit(next); next += 1 }
            while try await group.next() != nil {
                if cancel.isCancelled { group.cancelAll(); throw SFTPError(kind: .aborted, message: "Cancelled") }
                if next < files.count { submit(next); next += 1 }
            }
        }
    }

    private func runDownload(id: UUID, connection: SFTPConnection, remoteSource: String,
                             destination: URL, cancel: CancelFlag) async {
        guard let client = sftpClient(for: connection) else {
            settleTransfer(id, .failed("This server is misconfigured.")); return
        }
        let cap = settings.effectiveProfile.maxDownloadBytesPerSec
        // `downloadToFile` truncate-creates the destination up front, so any
        // non-success outcome (cancel, network stall, disk-full, remote gone)
        // leaves a partial file that must be cleaned up — not just on cancel.
        var succeeded = false
        do {
            let coalescer = ProgressCoalescer()
            try await client.downloadToFile(remote: remoteSource, localURL: destination,
                                            maxBytesPerSecond: cap,
                                            shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                guard coalescer.shouldEmit(isFinal: total > 0 && sofar >= total) else { return }
                Task { @MainActor in self?.setTransferProgress(id, bytes: sofar, total: total) }
            }
            succeeded = true
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }

    // MARK: Row bookkeeping (all on the main actor)

    private func setTransferBytes(_ id: UUID, _ bytes: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].record(bytes: bytes)
    }

    /// Record one file's progress within a parallel folder upload and report the
    /// summed aggregate as the row's byte count.
    private func setFolderFileBytes(_ id: UUID, index: Int, bytes: Int64) {
        sftpFolderBytes[id, default: [:]][index] = bytes
        let sum = sftpFolderBytes[id]?.values.reduce(0, +) ?? 0
        setTransferBytes(id, sum)
    }

    private func setTransferTotal(_ id: UUID, _ total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].total = total
    }

    private func setTransferProgress(_ id: UUID, bytes: Int64, total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        if total > 0 { sftpTransfers[i].total = total }
        sftpTransfers[i].record(bytes: bytes)
    }

    private func settleTransfer(_ id: UUID, _ state: SFTPTransfer.State) {
        sftpTransferTasks[id] = nil
        sftpFolderBytes[id] = nil
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        if state == .finished { sftpTransfers[i].bytes = max(sftpTransfers[i].bytes, sftpTransfers[i].total) }
        // A settled transfer contributes no throughput to the status-bar / menu-bar
        // totals or the sidebar indicator.
        sftpTransfers[i].speed = 0
        sftpTransfers[i].state = state
    }

    /// Settle a transfer that threw: an explicit abort is a user cancel, an
    /// `SFTPError` carries its own message, anything else falls back to the
    /// system description.
    private func settleTransfer(_ id: UUID, error: Error) {
        if let e = error as? SFTPError {
            settleTransfer(id, e.kind == .aborted ? .cancelled : .failed(e.message))
        } else {
            settleTransfer(id, .failed(error.localizedDescription))
        }
    }

    private func bumpMutation() { sftpMutationTick &+= 1 }

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

    init(scanning root: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let rootCount = root.pathComponents.count
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for case let url as URL in en {
            let rel = Array(url.pathComponents.dropFirst(rootCount))
            let vals = try? url.resourceValues(forKeys: keys)
            if vals?.isDirectory == true {
                dirs.append(rel)
            } else if vals?.isRegularFile == true {
                let size = Int64(vals?.fileSize ?? 0)
                files.append(File(url: url, rel: rel, size: size))
                total += size
            }
        }
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
