import Foundation
#if canImport(AppKit)
import AppKit
#endif
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
        // The previously saved endpoint matters as much as the new one: renaming a
        // host or user leaves a pooled connection under the OLD key that nothing
        // else would ever reach.
        let previous = server(connection.id)
        let outcome = SFTPConnectionStore.shared.save(connection, password: password,
                                                      keyPassphrase: keyPassphrase)
        reloadServers()
        // Pooled connections capture their credentials when they are opened, so
        // an edited password or key would otherwise keep reconnecting with the
        // old one until the app restarted.
        dropPooledConnections(for: connection, and: previous)
        return outcome
    }

    /// Close every live connection belonging to these endpoints.
    private func dropPooledConnections(for connection: SFTPConnection,
                                       and previous: SFTPConnection?) {
        var endpoints = [SFTPTarget(host: connection.host, port: connection.port,
                                    username: connection.username, password: nil)]
        if let previous, previous.host != connection.host || previous.port != connection.port
            || previous.username != connection.username {
            endpoints.append(SFTPTarget(host: previous.host, port: previous.port,
                                        username: previous.username, password: nil))
        }
        Task {
            for endpoint in endpoints where !endpoint.host.isEmpty {
                await SFTPSessionPool.shared.disconnectAll(matching: endpoint)
            }
        }
    }

    /// Delete a server and its stored password.
    func removeServer(_ id: SFTPConnection.ID) {
        if selectedServer == id { selectedServer = nil }
        if sftpBrowserNavigation?.connectionID == id { sftpBrowserNavigation = nil }
        // Read before the store forgets it — a removed server must not leave a
        // live, authenticated connection behind.
        if let going = server(id) { dropPooledConnections(for: going, and: nil) }
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

    // MARK: Session actions (sidebar context menu)
    //
    // A note on what "connected" means here. ``SFTPClient`` is a value type and
    // the C shim opens its own socket per call (`gsb_open` … `gsb_teardown`), so
    // there is no long-lived session to hang up on. What *is* long-lived is the
    // browsing state: the mounted `SFTPBrowserModel`, its cached listing and
    // remembered path, and any in-flight transfers. These three actions manage
    // that state, which is what a user means by connect/disconnect/reconnect.

    /// True when this server has something to disconnect *from*: it is the one
    /// being browsed, or it still has a transfer running.
    func isServerEngaged(_ id: SFTPConnection.ID) -> Bool {
        selectedServer == id || sftpTransfers.contains { $0.connectionID == id && $0.isActive }
    }

    /// Tear down everything holding this server open: stop its transfers and
    /// leave its browser. Asks first when transfers would be killed — the same
    /// bargain ``requestCancelSFTPTransfer(_:)`` strikes for a single row.
    func disconnectServer(_ id: SFTPConnection.ID) {
        // Reachable with nothing to do: the menu item is disabled in that state,
        // but the VoiceOver action that mirrors it carries no disabled state, so
        // the guard lives here rather than in the view.
        guard let connection = server(id), isServerEngaged(id) else { return }
        let active = activeTransfers(for: id)
        guard !active.isEmpty else {
            finishDisconnect(id)
            return
        }
        let count = active.count
        requestConfirm(
            title: "Disconnect from “\(connection.label)”?",
            message: count == 1
                ? "“\(active[0].name)” is still transferring. It will stop and be removed from the list."
                : "\(count) transfers are still running. They will stop and be removed from the list.",
            confirmTitle: "Disconnect",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            // Re-read rather than closing over the list the sheet was built from.
            // A queued upload can start while the sheet is open — cancelling the
            // stale snapshot would leave that one running under a "Disconnected"
            // toast, which is the one thing this action promises not to do.
            for transfer in self.activeTransfers(for: id) { self.cancelSFTPTransfer(transfer.id) }
            self.finishDisconnect(id)
        }
    }

    /// This server's still-running transfers.
    private func activeTransfers(for id: SFTPConnection.ID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.connectionID == id && $0.isActive }
    }

    /// The disconnect itself, once any transfers are settled.
    private func finishDisconnect(_ id: SFTPConnection.ID) {
        if selectedServer == id { closeServerBrowser() }
        if sftpBrowserNavigation?.connectionID == id { sftpBrowserNavigation = nil }
        serverTestsInFlight.remove(id)
        // Drop the one-shot OS-probe guard. Detection is also gated on `os` still
        // being nil, so this only matters for a probe that hadn't answered yet:
        // it lets a later reconnect try again instead of being blocked forever by
        // one this teardown outran.
        osProbesInFlight.remove(id)
        toastNow("Disconnected")
    }

    /// Re-open this server from scratch: a new browser against a freshly resolved
    /// client (so a changed password or key is picked up), plus an immediate
    /// reachability sweep. Works whether or not the server is currently open.
    func reconnectServer(_ id: SFTPConnection.ID) {
        guard server(id) != nil else { return }
        sftpBrowserNavigation = nil
        selectedServer = id
        // Let the OS chip be re-detected against the new session.
        osProbesInFlight.remove(id)
        bumpBrowserGeneration()
        toastNow("Reconnecting…")
        Task { await refreshServerStatuses() }
    }

    /// Open a real authenticated session and report what happened.
    ///
    /// The sidebar's live dot is a bare TCP connect — it never logs in, so a
    /// server with a stale password or an unapproved host key still shows green.
    /// This is the one action that answers "will this actually work?".
    func testServerConnection(_ connection: SFTPConnection) {
        let id = connection.id
        guard !serverTestsInFlight.contains(id) else { return }
        guard let client = sftpClientReportingFailure(for: connection) else { return }
        serverTestsInFlight.insert(id)
        toastNow("Testing “\(connection.label)”…")
        let endpoint = "\(connection.username)@\(connection.host)"
        Task { [weak self] in
            let started = Date()
            let outcome: String
            do {
                _ = try await client.probe()
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                outcome = "Connected as \(endpoint) · \(ms) ms"
            } catch let error as SFTPError {
                outcome = "Couldn’t connect: \(error.message)"
            } catch {
                outcome = "Couldn’t connect: \(error.localizedDescription)"
            }
            guard let self else { return }
            self.serverTestsInFlight.remove(id)
            self.toastNow(outcome)
        }
    }

    // MARK: Host key

    /// True when this server has a pin to show or forget. `.unavailable` counts:
    /// an unreadable record is exactly the state "Forget Host Key" exists to
    /// clear, and hiding the item there would strand the user.
    func hasHostKeyRecord(_ connection: SFTPConnection) -> Bool {
        HostKeyStore.shared.lookup(host: connection.host, port: connection.port) != .none
    }

    /// Show the pinned host key next to the one the server is presenting now.
    ///
    /// The live read is deliberately credential-free — `password: ""` skips the
    /// Keychain lookup entirely, and ``SFTPClient/hostKeyFingerprint()`` hangs up
    /// before offering anything. Asking the user to authorize a Keychain read just
    /// to look at a public fingerprint would be backwards, and the case that most
    /// needs this dialog is the one where the credentials no longer work.
    func showHostKey(_ connection: SFTPConnection) {
        let id = connection.id
        guard !hostKeyReadsInFlight.contains(id) else { return }
        let host = connection.host, port = connection.port
        let endpoint = port == 22 ? host : "\(host):\(port)"

        guard let client = SFTPSession.client(for: connection, password: "", keyPassphrase: "") else {
            HostKeyInspector.present(endpoint: endpoint,
                                     pinned: HostKeyStore.shared.lookup(host: host, port: port),
                                     live: .unreachable("this server has no address saved."))
            return
        }
        hostKeyReadsInFlight.insert(id)
        toastNow("Reading host key…")
        Task { [weak self] in
            let live: HostKeyInspector.LiveKey
            do {
                live = .read(try await client.hostKeyFingerprint())
            } catch let error as SFTPError {
                live = .unreachable(error.message)
            } catch {
                live = .unreachable(error.localizedDescription)
            }
            guard let self else { return }
            self.hostKeyReadsInFlight.remove(id)
            // Read the pin *after* the round-trip, not before it. A first-contact
            // approval on another connection to this host can pin a key during
            // those seconds, and a dialog captioned "Pinned" showing a key that is
            // no longer the pin is worse than one that admits it doesn't know.
            HostKeyInspector.present(endpoint: endpoint,
                                     pinned: HostKeyStore.shared.lookup(host: host, port: port),
                                     live: live)
        }
    }

    /// Forget the pinned fingerprint, so the next connection asks about the key
    /// again — the recovery after a legitimate rekey, and the only way out of a
    /// pin record Goel can no longer read (both fail closed and block every
    /// connection). Same action as the connection editor's "Reset pinned host
    /// key"; this is the route that doesn't require opening the editor.
    ///
    /// Always confirmed: forgetting a pin drops the protection that makes a
    /// swapped host key visible, and the next connection will accept whatever
    /// answers on the strength of the user's approval alone.
    func forgetHostKey(_ connection: SFTPConnection) {
        let host = connection.host, port = connection.port
        requestConfirm(
            title: "Forget the host key for “\(connection.label)”?",
            message: """
                Goel will stop checking this server against its saved key and will ask \
                you to confirm the key on the next connection.

                Do this only after you rekeyed the server yourself. If the key changed \
                for any other reason, forgetting it accepts whatever is answering.
                """,
            confirmTitle: "Forget Key",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            guard HostKeyStore.shared.reset(host: host, port: port) else {
                self.toastNow("Couldn’t clear the saved host key for \(host)")
                return
            }
            self.toastNow("Host key forgotten — you’ll be asked to confirm it next connection")
        }
    }

    /// `ssh://user@host:port` — handed to whichever app owns the scheme (Terminal
    /// by default).
    func sshURL(for connection: SFTPConnection) -> URL? {
        Self.sshURL(username: connection.username, host: connection.host, port: connection.port)
    }

    /// The pure builder behind ``sshURL(for:)``, kept `nonisolated static` so the
    /// escaping is testable without standing up a whole view model.
    ///
    /// Built through `URLComponents` rather than string interpolation: this URL is
    /// handed to `NSWorkspace`, and a username carrying an `@`, a `/` or a space
    /// would otherwise re-point the host half of the address at something the user
    /// never saved. The port is omitted at 22 so the common case reads cleanly.
    nonisolated static func sshURL(username: String, host: String, port: Int) -> URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "ssh"
        if !username.isEmpty { components.user = username }
        components.host = host
        if port != 22 { components.port = port }
        return components.url
    }

    /// Hand the server to Terminal (or whatever claims `ssh://`).
    ///
    /// This leaves Goel: the external client uses its own `known_hosts`, not the
    /// fingerprint pinned in ``HostKeyStore``, and will do its own trust prompt.
    func openServerInTerminal(_ connection: SFTPConnection) {
        guard let url = sshURL(for: connection) else {
            toastNow("This server’s address can’t be opened in Terminal")
            return
        }
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else {
            toastNow("No app is set up to open ssh:// links")
            return
        }
        #endif
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
