import Foundation
import GoelCore

/// The UI side of sending downloads to a saved SFTP server.
///
/// Every entry point here checks ``AppSettings/sftpDestinationEnabled`` before offering anything. Gating only the transfer would be worse than not having the feature: the user could pick a destination and the file would silently never arrive.
@MainActor
extension AppViewModel {

    /// Whether the feature is switched on. Drives whether the picker, the badges and the menu items exist at all — not merely whether they are greyed out.
    var isSendToServerEnabled: Bool { settings.sftpDestinationEnabled }

    /// Servers that can be offered as a destination.
    ///
    /// A server with no pinned host key is deliberately excluded rather than shown-and-refused: the upload runs unattended, so it must never be the moment a key is learned. Browsing the server once pins it and the entry appears.
    var destinationServers: [SFTPConnection] {
        guard isSendToServerEnabled else { return [] }
        return servers.filter { HostKeyStore.shared.fingerprint(host: $0.host, port: $0.port) != nil }
    }

    /// Saved servers that cannot be offered yet, so the UI can say why instead of hiding them without explanation.
    var unpinnedServers: [SFTPConnection] {
        guard isSendToServerEnabled else { return [] }
        return servers.filter { HostKeyStore.shared.fingerprint(host: $0.host, port: $0.port) == nil }
    }

    /// Build a destination for a server, defaulting the folder to its configured upload path.
    func makeDestination(for connection: SFTPConnection,
                         directory: String? = nil,
                         removeLocalAfterUpload: Bool) -> RemoteDestination {
        RemoteDestination(connectionID: connection.id,
                          serverLabel: connection.label,
                          directory: directory ?? connection.resolvedUploadPath,
                          removeLocalAfterUpload: removeLocalAfterUpload)
    }

    /// Validate a destination folder before it is attached to a download, so a bad path is caught while the user is still looking at the field.
    func destinationFolderError(_ raw: String) -> String? {
        if case .failure(let rejection) = RemotePathSafety.validateDirectory(raw) {
            return rejection.message
        }
        return nil
    }

    // MARK: Actions

    /// Whether a download's payload is a shape that can be sent — a single file, not a folder of them.
    func canSendToServer(_ task: DownloadTask) -> Bool {
        isSendToServerEnabled && !task.isMultiFile
    }

    /// Open the "Send to server" sheet for a finished download.
    func presentSendToServer(_ task: DownloadTask) {
        guard isSendToServerEnabled else { return }
        guard task.status == .completed else { return toastNow("Only finished downloads can be sent") }
        guard !task.isMultiFile else { return toastNow(DownloadManager.multiFileRefusal) }
        guard !destinationServers.isEmpty else {
            return toastNow(servers.isEmpty ? "Add a server first" : "Browse the server once so its identity can be checked")
        }
        sendToServerTask = task
    }

    /// Send a finished download to a server. A copy, not a move — the local file only goes if `removeLocalAfterUpload` was ticked, and only after the upload verifies.
    func sendToServer(_ task: DownloadTask, destination: RemoteDestination) {
        guard isSendToServerEnabled else { return }
        sendToServerTask = nil
        Task {
            let accepted = await manager.sendToServer(task.id, destination: destination)
            toastNow(accepted ? "Sending to \(destination.serverLabel)…"
                              : "Couldn’t start the transfer — the file may have moved")
        }
    }

    func retryRemoteUpload(_ task: DownloadTask) {
        guard isSendToServerEnabled else { return }
        Task {
            await manager.retryRemoteUpload(task.id)
            toastNow("Retrying…")
        }
    }

    /// Stop a transfer in progress. Awaits teardown, so the local file is safe to touch once the toast appears.
    func stopRemoteUpload(_ task: DownloadTask) {
        Task {
            await manager.stopRemoteUpload(task.id)
            toastNow("Transfer stopped — the local copy is untouched")
        }
    }

    func clearRemoteDestination(_ task: DownloadTask) {
        Task {
            await manager.clearRemoteDestination(task.id)
            toastNow("Destination removed")
        }
    }

    // MARK: Display

    /// One line describing where a download is going, or has gone.
    func remoteStatusText(_ task: DownloadTask) -> String? {
        guard let destination = task.remoteDestination else { return nil }
        switch destination.state {
        case .pending:   return "Waiting to send to \(destination.serverLabel)"
        case .uploading:
            guard let total = task.totalBytes, total > 0 else {
                return "Sending to \(destination.serverLabel)…"
            }
            let percent = Int((Double(destination.bytesTransferred) / Double(total)) * 100)
            return "Sending to \(destination.serverLabel) — \(min(100, percent))%"
        case .uploaded:  return "On \(destination.displayLocation)"
        case .failed:    return destination.failureMessage ?? "Could not send to \(destination.serverLabel)"
        case .held:      return destination.failureMessage ?? "Held"
        }
    }

    /// Progress of the upload leg, 0…1, or nil when nothing is in flight.
    func remoteUploadFraction(_ task: DownloadTask) -> Double? {
        guard let destination = task.remoteDestination, destination.state.isInFlight,
              let total = task.totalBytes, total > 0 else { return nil }
        return min(1, Double(destination.bytesTransferred) / Double(total))
    }
}
