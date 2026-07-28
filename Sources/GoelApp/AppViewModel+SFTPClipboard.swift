import Foundation
import GoelCore

/// Copy / cut / paste of remote items. Bytes travel through this machine, except a *move*
/// inside one server, which is a RENAME — instant regardless of size.
@MainActor
extension AppViewModel {

    // MARK: Clipboard

    /// Put items on the remote clipboard. Replaces whatever was there — the same
    /// single-slot behaviour Finder has.
    func copySFTPItems(_ entries: [SFTPEntry], from connection: SFTPConnection,
                       directory: String, operation: SFTPClipboard.Operation) {
        let safe = entries.filter { SFTPBrowserPaths.isSafeChildName($0.name) }
        guard !safe.isEmpty else { return }
        sftpClipboard = SFTPClipboard(operation: operation, connectionID: connection.id,
                                      directory: directory, items: safe)
        let noun = safe.count == 1 ? "“\(safe[0].name)”" : "\(safe.count) items"
        toastNow(operation == .cut ? "Cut \(noun)" : "Copied \(noun)")
    }

    func clearSFTPClipboard() { sftpClipboard = nil }

    /// Whether a paste into this folder would do anything.
    func canPasteSFTP(into connection: SFTPConnection, directory: String) -> Bool {
        guard let clip = sftpClipboard, !clip.isEmpty else { return false }
        return !clip.isSelfMove(toConnection: connection.id, directory: directory)
    }

    // MARK: Paste

    /// Paste the clipboard into `directory` on `connection`. A cut is cleared once started
    /// (the source is about to vanish); a copy stays, so it can be pasted repeatedly.
    func pasteSFTPClipboard(into connection: SFTPConnection, directory: String) {
        guard let clip = sftpClipboard, !clip.isEmpty else { return }
        guard !clip.isSelfMove(toConnection: connection.id, directory: directory) else { return }
        guard let source = server(clip.connectionID) else {
            toastNow("The server those items came from is no longer set up."); return
        }
        // Resolved once per paste, not per item, so a multi-item paste raises at
        // most one Keychain prompt per server.
        guard let sourceClient = sftpClientReportingFailure(for: source) else { return }
        let destinationClient: SFTPClient
        if clip.connectionID == connection.id {
            destinationClient = sourceClient
        } else {
            guard let resolved = sftpClientReportingFailure(for: connection) else { return }
            destinationClient = resolved
        }

        let sameServer = clip.connectionID == connection.id
        for entry in clip.items {
            guard !clip.wouldRecurse(entry, intoConnection: connection.id, directory: directory) else {
                toastNow("Can’t paste “\(entry.name)” inside itself.")
                continue
            }
            startRemoteCopy(entry: entry, clip: clip,
                            sourceClient: sourceClient, destination: connection,
                            destinationClient: destinationClient, directory: directory,
                            isMove: clip.operation == .cut, sameServer: sameServer)
        }
        if clip.operation == .cut { sftpClipboard = nil }
    }

    /// Duplicate items in place — Finder's ⌘D. A copy into the folder the item is
    /// already in, so it always collides and always lands on a "name copy" name.
    func duplicateSFTPItems(_ entries: [SFTPEntry], on connection: SFTPConnection, directory: String) {
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        let clip = SFTPClipboard(operation: .copy, connectionID: connection.id,
                                 directory: directory, items: entries)
        for entry in entries where SFTPBrowserPaths.isSafeChildName(entry.name) {
            startRemoteCopy(entry: entry, clip: clip, sourceClient: client,
                            destination: connection, destinationClient: client,
                            directory: directory, isMove: false, sameServer: true)
        }
    }

    // MARK: One item

    private func startRemoteCopy(entry: SFTPEntry, clip: SFTPClipboard,
                                 sourceClient: SFTPClient, destination: SFTPConnection,
                                 destinationClient: SFTPClient, directory: String,
                                 isMove: Bool, sameServer: Bool) {
        let sourcePath = clip.sourcePath(entry)
        let cancel = CancelFlag()
        let transfer = SFTPTransfer(connectionID: destination.id, name: entry.name,
                                    direction: .remoteCopy, isDirectory: entry.isDirectory,
                                    localURL: nil,
                                    remotePath: SFTPBrowserPaths.join(directory, entry.name),
                                    total: entry.isDirectory ? 0 : entry.size)
        sftpTransfers.append(transfer)
        let id = transfer.id
        let plan = RemoteCopyPlan(entry: entry, sourcePath: sourcePath,
                                  destinationDirectory: directory,
                                  sourceConnectionID: clip.connectionID,
                                  destinationConnectionID: destination.id,
                                  isMove: isMove, sameServer: sameServer)
        sftpRemoteCopyPlans[id] = plan
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRemoteCopy(id: id, plan: plan, source: sourceClient,
                                         destination: destinationClient, cancel: cancel)
        }
        sftpTransferTasks[id] = (task, cancel)
    }

    /// Replay a failed remote copy. Re-resolves both clients, because the row
    /// may have outlived an edit to either server's credentials.
    func runRemoteCopy(id: UUID, cancel: CancelFlag) async {
        guard let plan = sftpRemoteCopyPlans[id],
              let sourceConnection = server(plan.sourceConnectionID),
              let destinationConnection = server(plan.destinationConnectionID) else {
            settleTransfer(id, .failed("The servers for this copy are no longer set up."))
            return
        }
        guard let source = sftpClientReportingFailure(for: sourceConnection) else {
            settleTransfer(id, .failed("Couldn’t reach the source server.")); return
        }
        let destination = plan.sameServer ? source : sftpClient(for: destinationConnection)
        guard let destination else {
            settleTransfer(id, .failed("Couldn’t reach the destination server.")); return
        }
        await performRemoteCopy(id: id, plan: plan, source: source,
                                destination: destination, cancel: cancel)
    }

    private func performRemoteCopy(id: UUID, plan: RemoteCopyPlan,
                                   source sourceClient: SFTPClient,
                                   destination destinationClient: SFTPClient,
                                   cancel: CancelFlag) async {
        // Read and write halves must never share a connection: one libssh2 session is one thread
        // and would deadlock. On one server, reserve both together or two copies can hang.
        let readJob = UUID(), writeJob = UUID()
        let reader = sourceClient.forTransfer(readJob)
        let writer = destinationClient.forTransfer(writeJob)
        let cap = settings.effectiveProfile.maxDownloadBytesPerSec

        if plan.sameServer {
            await sourceClient.reserveSlots(2)
        } else {
            // Different servers draw on different budgets, so neither half can be
            // starved by the other.
            await sourceClient.reserveSlots(1)
            await destinationClient.reserveSlots(1)
        }

        do {
            // A rename is the whole operation when moving inside one server, so
            // check for that before doing anything that costs bytes.
            let name = try await SFTPRelay.resolvedName(plan.entry.name,
                                                        in: plan.destinationDirectory,
                                                        on: writer,
                                                        policy: .rename)
            guard let name else { throw SFTPError(kind: .io, message: "That name is already taken.") }
            let target = SFTPBrowserPaths.join(plan.destinationDirectory, name)
            renameTransferRow(id, to: name)

            if plan.isMove && plan.sameServer {
                // One round trip regardless of size. A server that refuses (different filesystems)
                // falls through to the relay, the only way across a mount boundary.
                do {
                    try await writer.rename(plan.sourcePath, to: target)
                    setTransferProgress(id, bytes: plan.entry.size, total: plan.entry.size)
                    settleTransfer(id, .finished)
                    await releaseCopyConnections(plan: plan, reader: reader, readJob: readJob,
                                                 writer: writer, writeJob: writeJob,
                                                 source: sourceClient, destination: destinationClient)
                    bumpMutation()
                    return
                } catch {
                    // Fall through and copy instead.
                }
            }

            if plan.entry.isDirectory {
                let total = try await SFTPRelay.treeSize(reader, path: plan.sourcePath,
                                                         shouldContinue: { !cancel.isCancelled })
                setTransferTotal(id, total)
                let done = CopiedBytes()
                try await SFTPRelay.copyTree(
                    from: reader, path: plan.sourcePath, to: writer, path: target,
                    maxBytesPerSecond: cap,
                    shouldContinue: { !cancel.isCancelled },
                    onFileStart: { _, _ in done.startFile() },
                    onFileProgress: { [weak self] _, sofar in
                        let running = done.progress(sofar)
                        guard let self else { return }
                        Task { @MainActor in self.setTransferBytes(id, running) }
                    })
            } else {
                setTransferTotal(id, plan.entry.size)
                try await SFTPRelay.copyFile(
                    from: reader, path: plan.sourcePath, to: writer, path: target,
                    size: plan.entry.size, maxBytesPerSecond: cap,
                    shouldContinue: { !cancel.isCancelled },
                    progress: { [weak self] sofar, _ in
                        guard let self else { return }
                        Task { @MainActor in self.setTransferBytes(id, sofar) }
                    })
            }

            // Only now is the source safe to remove. A failure here is not a failed copy — every
            // byte arrived — so say so, or the user re-runs the move and ends up with two copies.
            if plan.isMove {
                do {
                    try await reader.remove(plan.sourcePath, isDirectory: plan.entry.isDirectory)
                } catch {
                    let detail = (error as? SFTPError)?.message ?? error.localizedDescription
                    settleTransfer(id, .failed("Copied “\(plan.entry.name)” to the destination, but the original couldn’t be deleted — delete it by hand. \(detail)"))
                    await releaseCopyConnections(plan: plan, reader: reader, readJob: readJob,
                                                 writer: writer, writeJob: writeJob,
                                                 source: sourceClient, destination: destinationClient)
                    bumpMutation()
                    return
                }
            }
            settleTransfer(id, .finished)
        } catch {
            settleTransfer(id, error: error)
        }
        await releaseCopyConnections(plan: plan, reader: reader, readJob: readJob,
                                     writer: writer, writeJob: writeJob,
                                     source: sourceClient, destination: destinationClient)
        bumpMutation()
    }

    /// Hand back both halves of a relay: the channels themselves, and then the
    /// paired reservation that admitted them.
    private func releaseCopyConnections(plan: RemoteCopyPlan,
                                        reader: SFTPClient, readJob: UUID,
                                        writer: SFTPClient, writeJob: UUID,
                                        source: SFTPClient, destination: SFTPClient) async {
        await reader.finishTransfer(readJob)
        await writer.finishTransfer(writeJob)
        if plan.sameServer {
            await source.releaseSlots(2)
        } else {
            await source.releaseSlots(1)
            await destination.releaseSlots(1)
        }
    }

    /// Point a row at the name it actually landed on, after collision renaming.
    private func renameTransferRow(_ id: UUID, to name: String) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].name = name
    }
}

/// Everything needed to replay one remote copy after a failure.
struct RemoteCopyPlan {
    let entry: SFTPEntry
    let sourcePath: String
    let destinationDirectory: String
    let sourceConnectionID: UUID
    let destinationConnectionID: UUID
    let isMove: Bool
    let sameServer: Bool
}

/// The running byte total of a tree copy. Files copy one at a time, so a single "current
/// file" slot suffices. `@unchecked Sendable`: both fields are only touched under `lock`.
final class CopiedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var current: Int64 = 0

    /// A new file has started; bank the previous one's final count.
    func startFile() {
        lock.lock(); defer { lock.unlock() }
        completed += current
        current = 0
    }

    /// Absorb the current file's absolute byte count and return the tree total.
    func progress(_ bytes: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        current = bytes
        return completed + current
    }
}
