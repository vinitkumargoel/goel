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
        let safeName = DownloadTask.sanitizedName(entry.name)
        let destination = localDir.appendingPathComponent(safeName)
        guard SFTPBrowserModel.isContained(destination, in: localDir) else {
            toastNow("Refusing to write “\(entry.name)” outside the chosen folder."); return
        }
        let remoteSource = SFTPBrowserPaths.join(remoteDir, entry.name)
        let cancel = CancelFlag()
        let transfer = SFTPTransfer(connectionID: connection.id, name: safeName, direction: .download,
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

    /// Abort an in-flight transfer. The libssh2 thread observes the flag on its
    /// next progress tick and returns; the state flips to `.cancelled` then.
    func cancelSFTPTransfer(_ id: UUID) {
        guard let entry = sftpTransferTasks[id] else { return }
        entry.cancel.cancel()
        entry.task.cancel()
        toastNow("Transfer cancelled")
    }

    /// Re-run a failed/cancelled transfer in place (same row, reset counters).
    func retrySFTPTransfer(_ id: UUID) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }), !sftpTransfers[i].isActive else { return }
        let t = sftpTransfers[i]
        guard let connection = server(t.connectionID) else { toastNow("That server no longer exists."); return }
        sftpTransfers[i].state = .running
        sftpTransfers[i].bytes = 0
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
        for url in items {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = SFTPUploadConflictRequest.Item(url: url, isDirectory: isDir)
            if existing.contains(url.lastPathComponent) { colliding.append(item) } else { free.append(item) }
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
                try await client.upload(localURL: localURL, remote: remoteTarget, maxBytesPerSecond: cap,
                                        shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, _ in
                    Task { @MainActor in self?.setTransferBytes(id, sofar) }
                }
            }
            settleTransfer(id, .finished)
        } catch let e as SFTPError where e.kind == .aborted {
            settleTransfer(id, .cancelled)
        } catch let e as SFTPError {
            settleTransfer(id, .failed(e.message))
        } catch {
            settleTransfer(id, .failed(error.localizedDescription))
        }
        // Any outcome may have created/partially-written remote files
        // (libssh2 opens with CREAT), so refresh a browser on this server.
        bumpMutation()
    }

    /// Recreate a local folder tree on the server and upload its files, keeping
    /// the row's byte counters as a running total across the whole subtree.
    private func uploadFolder(id: UUID, client: SFTPClient, root: URL,
                              remoteRoot: String, cap: Int64, cancel: CancelFlag) async throws {
        // Walk the tree off the main actor so a large folder doesn't hitch the UI.
        let scan = await Task.detached { FolderScan(scanning: root) }.value
        setTransferTotal(id, scan.total)

        // Directories first (shallowest → deepest) so every file's parent exists.
        // mkdir on an existing dir errors; ignore it so overwrite/merge works.
        _ = try? await client.mkdir(remoteRoot)
        for rel in scan.dirs.sorted(by: { $0.count < $1.count }) {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
            _ = try? await client.mkdir(rel.reduce(remoteRoot, SFTPBrowserPaths.join))
        }

        var base: Int64 = 0
        for file in scan.files {
            if cancel.isCancelled { throw SFTPError(kind: .aborted, message: "Cancelled") }
            let remoteFile = file.rel.reduce(remoteRoot, SFTPBrowserPaths.join)
            let fileBase = base
            try await client.upload(localURL: file.url, remote: remoteFile, maxBytesPerSecond: cap,
                                    shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, _ in
                Task { @MainActor in self?.setTransferBytes(id, fileBase + sofar) }
            }
            base += file.size
            setTransferBytes(id, base)
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
            try await client.downloadToFile(remote: remoteSource, localURL: destination,
                                            maxBytesPerSecond: cap,
                                            shouldContinue: { !cancel.isCancelled }) { [weak self] sofar, total in
                Task { @MainActor in self?.setTransferProgress(id, bytes: sofar, total: total) }
            }
            succeeded = true
            settleTransfer(id, .finished)
        } catch let e as SFTPError where e.kind == .aborted {
            settleTransfer(id, .cancelled)
        } catch let e as SFTPError {
            settleTransfer(id, .failed(e.message))
        } catch {
            settleTransfer(id, .failed(error.localizedDescription))
        }
        if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }

    // MARK: Row bookkeeping (all on the main actor)

    private func setTransferBytes(_ id: UUID, _ bytes: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].bytes = bytes
    }

    private func setTransferTotal(_ id: UUID, _ total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].total = total
    }

    private func setTransferProgress(_ id: UUID, bytes: Int64, total: Int64) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].bytes = bytes
        if total > 0 { sftpTransfers[i].total = total }
    }

    private func settleTransfer(_ id: UUID, _ state: SFTPTransfer.State) {
        sftpTransferTasks[id] = nil
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        if state == .finished { sftpTransfers[i].bytes = max(sftpTransfers[i].bytes, sftpTransfers[i].total) }
        sftpTransfers[i].state = state
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
