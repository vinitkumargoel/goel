import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    func copySFTPItems(_ entries: [SFTPEntry], from connection: SFTPConnection,
                       directory: String, operation: SFTPClipboard.Operation) {
        let safe = entries.filter { SFTPBrowserPaths.isSafeChildName($0.name) }
        guard !safe.isEmpty else { return }
        sftpClipboard = SFTPClipboard(operation: operation, connectionID: connection.id,
                                      directory: directory, items: safe)
        let noun = safe.count == 1 ? "“\(safe[0].name)”" : L10n.t("%d items", safe.count)
        toastNow(operation == .cut ? L10n.t("Cut %@", noun) : L10n.t("Copied %@", noun))
    }

    func clearSFTPClipboard() { sftpClipboard = nil }

    func canPasteSFTP(into connection: SFTPConnection, directory: String) -> Bool {
        guard let clip = sftpClipboard, !clip.isEmpty else { return false }
        return !clip.isSelfMove(toConnection: connection.id, directory: directory)
    }

    func pasteSFTPClipboard(into connection: SFTPConnection, directory: String) {
        guard let clip = sftpClipboard, !clip.isEmpty else { return }
        guard !clip.isSelfMove(toConnection: connection.id, directory: directory) else { return }
        guard let source = server(clip.connectionID) else {
            toastNow(L10n.t("The server those items came from is no longer set up.")); return
        }
        // Resolve clients once per paste, not per item: otherwise one Keychain prompt per item.
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
                toastNow(L10n.t("Can’t paste “%@” inside itself.", entry.name))
                continue
            }
            startRemoteCopy(entry: entry, clip: clip,
                            sourceClient: sourceClient, destination: connection,
                            destinationClient: destinationClient, directory: directory,
                            isMove: clip.operation == .cut, sameServer: sameServer)
        }
        if clip.operation == .cut { sftpClipboard = nil }
    }

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

    /// Re-resolves both clients: the row may have outlived an edit to either server's credentials.
    func runRemoteCopy(id: UUID, cancel: CancelFlag) async {
        guard let plan = sftpRemoteCopyPlans[id],
              let sourceConnection = server(plan.sourceConnectionID),
              let destinationConnection = server(plan.destinationConnectionID) else {
            settleTransfer(id, .failed(L10n.t("The servers for this copy are no longer set up.")))
            return
        }
        guard let source = sftpClientReportingFailure(for: sourceConnection) else {
            settleTransfer(id, .failed(L10n.t("Couldn’t reach the source server."))); return
        }
        let destination = plan.sameServer ? source : sftpClient(for: destinationConnection)
        guard let destination else {
            settleTransfer(id, .failed(L10n.t("Couldn’t reach the destination server."))); return
        }
        await performRemoteCopy(id: id, plan: plan, source: source,
                                destination: destination, cancel: cancel)
    }

    private func performRemoteCopy(id: UUID, plan: RemoteCopyPlan,
                                   source sourceClient: SFTPClient,
                                   destination destinationClient: SFTPClient,
                                   cancel: CancelFlag) async {
        // Read and write halves must never share a connection (one libssh2 session is one thread — deadlock); on one server reserve both slots together or two copies hang.
        let readJob = UUID(), writeJob = UUID()
        let reader = sourceClient.forTransfer(readJob)
        let writer = destinationClient.forTransfer(writeJob)
        let cap = settings.effectiveProfile.maxDownloadBytesPerSec

        if plan.sameServer {
            await sourceClient.reserveSlots(2)
        } else {
            await sourceClient.reserveSlots(1)
            await destinationClient.reserveSlots(1)
        }

        do {
            let name = try await SFTPRelay.resolvedName(plan.entry.name,
                                                        in: plan.destinationDirectory,
                                                        on: writer,
                                                        policy: .rename)
            guard let name else { throw SFTPError(kind: .io, message: L10n.t("That name is already taken.")) }
            let target = SFTPBrowserPaths.join(plan.destinationDirectory, name)
            renameTransferRow(id, to: name)

            if plan.isMove && plan.sameServer {
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
                    // Rename fails across mount boundaries; fall through to the byte copy.
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

            // Delete the source only after every byte landed, and report a failure here as "copied but not deleted" — otherwise a re-run duplicates.
            if plan.isMove {
                do {
                    try await reader.remove(plan.sourcePath, isDirectory: plan.entry.isDirectory)
                } catch {
                    let detail = (error as? SFTPError)?.message ?? error.localizedDescription
                    settleTransfer(id, .failed(
                        L10n.t("Copied “%1$@” to the destination, but the original couldn’t be "
                            + "deleted — delete it by hand. %2$@", plan.entry.name, detail)))
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

    private func renameTransferRow(_ id: UUID, to name: String) {
        guard let i = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[i].name = name
    }
}

struct RemoteCopyPlan {
    let entry: SFTPEntry
    let sourcePath: String
    let destinationDirectory: String
    let sourceConnectionID: UUID
    let destinationConnectionID: UUID
    let isMove: Bool
    let sameServer: Bool
}

/// `@unchecked Sendable`: both fields are only touched under `lock`.
final class CopiedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var current: Int64 = 0

    func startFile() {
        lock.lock(); defer { lock.unlock() }
        completed += current
        current = 0
    }

    /// `bytes` is the current file's absolute count, not a delta.
    func progress(_ bytes: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        current = bytes
        return completed + current
    }
}
