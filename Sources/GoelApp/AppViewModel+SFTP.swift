import Foundation
import GoelCore

/// SFTP server management: the sidebar "Servers" list, the add/edit editor, and
/// the bridge that turns a saved connection into a usable ``SFTPClient``.
@MainActor
extension AppViewModel {

    /// Reload the saved servers from disk into the published list.
    func reloadServers() {
        servers = SFTPConnectionStore.shared.load()
    }

    /// The connection for an id, if it still exists.
    func server(_ id: SFTPConnection.ID?) -> SFTPConnection? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    /// Open the editor to add a brand-new server.
    func presentNewServer() {
        editingServer = nil
        isServerEditorPresented = true
    }

    /// Open the editor to change an existing server.
    func presentEditServer(_ connection: SFTPConnection) {
        editingServer = connection
        isServerEditorPresented = true
    }

    /// Persist a server (password nil = keep the stored one) and refresh the list.
    func saveServer(_ connection: SFTPConnection, password: String?) {
        SFTPConnectionStore.shared.save(connection, password: password)
        reloadServers()
    }

    /// Delete a server and its stored password.
    func removeServer(_ id: SFTPConnection.ID) {
        if selectedServer == id { selectedServer = nil }
        SFTPConnectionStore.shared.remove(id)
        reloadServers()
        toastNow("Server removed")
    }

    /// Select a server for browsing (clears the download-list selection focus).
    func selectServer(_ id: SFTPConnection.ID) {
        selectedServer = id
    }

    /// Leave the browser and return to the download list.
    func closeServerBrowser() {
        selectedServer = nil
    }

    /// Build a usable client for a connection, resolving the Keychain password.
    /// Returns nil only if the connection is malformed (no host).
    func sftpClient(for connection: SFTPConnection) -> SFTPClient? {
        SFTPSession.client(for: connection)
    }

    /// The `sftp://user@host:port/path` locator for a remote file on a server,
    /// used to hand a browsed file to the normal download queue.
    func sftpLocator(for connection: SFTPConnection, remotePath: String) -> String {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = connection.username
        components.host = connection.host
        if connection.port != 22 { components.port = connection.port }
        components.path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        return components.string ?? "sftp://\(connection.username)@\(connection.host)\(remotePath)"
    }

    /// Enqueue a browsed remote file into the normal download list.
    func enqueueSFTPDownload(connection: SFTPConnection, remotePath: String) {
        add(rawLines: sftpLocator(for: connection, remotePath: remotePath),
            saveDirectory: nil, priority: .normal)
    }
}
