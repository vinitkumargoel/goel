import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    /// A file pulled from a server is as untrusted as one from the web: Gatekeeper must check it.
    /// Off the main actor, since a folder means a walk.
    func quarantineDownload(_ transfer: SFTPTransfer) {
        guard transfer.direction == .download, let local = transfer.localURL else { return }
        let source = server(transfer.connectionID).flatMap { Self.sftpSourceURL($0, remotePath: transfer.remotePath) }
        Task.detached(priority: .utility) {
            let failed = Quarantine.mark(local, sourceURL: source, referrer: nil)
            if failed > 0 {
                GoelLog.app.error("Couldn't quarantine an SFTP download", .count(failed, label: "items"))
            }
        }
    }

    nonisolated static func sftpSourceURL(_ connection: SFTPConnection, remotePath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "sftp"
        comps.host = connection.host
        comps.port = connection.port == 22 ? nil : connection.port
        comps.path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        return comps.url
    }
}
