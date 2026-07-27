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
    /// Returns what happened to the secrets so the editor can report a Keychain
    /// refusal instead of dismissing on a save the user cannot rely on.
    @discardableResult
    func saveServer(_ connection: SFTPConnection, password: String?,
                    keyPassphrase: String? = nil) -> CredentialWrite {
        let outcome = SFTPConnectionStore.shared.save(connection, password: password,
                                                      keyPassphrase: keyPassphrase)
        reloadServers()
        return outcome
    }

    /// Delete a server and its stored password.
    func removeServer(_ id: SFTPConnection.ID) {
        if selectedServer == id { selectedServer = nil }
        if sftpBrowserNavigation?.connectionID == id { sftpBrowserNavigation = nil }
        SFTPBrowserLocationStore.shared.removePath(for: id)
        SFTPConnectionStore.shared.remove(id)
        reloadServers()
        toastNow("Server removed")
    }

    /// Select a server for browsing (clears any transfer-generated destination).
    func selectServer(_ id: SFTPConnection.ID) {
        sftpBrowserNavigation = nil
        selectedServer = id
    }

    /// Open the remote folder containing a transfer's source/destination item.
    func revealSFTPTransfer(_ transfer: SFTPTransfer) {
        guard server(transfer.connectionID) != nil else {
            toastNow("Server is no longer available")
            return
        }
        sftpBrowserNavigation = SFTPBrowserNavigationRequest(
            connectionID: transfer.connectionID,
            path: transfer.remoteFolder)
        selectedServer = transfer.connectionID
    }

    /// Clear only the request a browser actually finished handling. A stale task
    /// must not erase a newer click that arrived while it was listing.
    func acknowledgeSFTPBrowserNavigation(_ requestID: UUID) {
        guard sftpBrowserNavigation?.id == requestID else { return }
        sftpBrowserNavigation = nil
    }

    /// Leave the browser and return to the download list.
    func closeServerBrowser() {
        sftpBrowserNavigation = nil
        selectedServer = nil
    }

    /// Build a usable client for a connection, resolving the Keychain password.
    /// Returns nil if the connection is malformed (no host) *or* the stored
    /// secret couldn't be read. Silent by design — it is called during view
    /// construction, where a toast would fire on every render. User-initiated
    /// actions should use ``sftpClientReportingFailure(for:)`` instead.
    func sftpClient(for connection: SFTPConnection) -> SFTPClient? {
        SFTPSession.client(for: connection)
    }

    /// Resolve a client **once**, returning either it or the reason it failed.
    ///
    /// A single entry point on purpose: each resolution can raise its own
    /// Keychain authorization prompt, so a "get the client, then ask why it
    /// failed" pair would prompt the user twice for one action. Callers must not
    /// combine `sftpClient(for:)` with a separate message lookup.
    ///
    /// A refused Keychain prompt previously surfaced as "This server is
    /// misconfigured", sending the user to re-check settings that were fine.
    func sftpClientOrFailure(for connection: SFTPConnection) -> (client: SFTPClient?, failure: String?) {
        switch SFTPSession.resolve(for: connection) {
        case .ready(let client):
            return (client, nil)
        case .incomplete:
            return (nil, "This server is misconfigured.")
        case .credentialsUnavailable(let lookup):
            return (nil, lookup.isRetryable
                ? "Goel wasn't allowed to read this server's saved secret from your Keychain. Try again and choose Allow."
                : "This server's saved secret couldn't be read from your Keychain.")
        }
    }

    /// Client for a user-initiated action, toasting the real reason on failure.
    func sftpClientReportingFailure(for connection: SFTPConnection) -> SFTPClient? {
        let (client, failure) = sftpClientOrFailure(for: connection)
        if let failure { toastNow(failure) }
        return client
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
