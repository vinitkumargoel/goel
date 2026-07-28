import Foundation
#if canImport(AppKit)
import AppKit
#endif
import GoelCore

@MainActor
extension AppViewModel {

    func reloadServers() {
        servers = SFTPConnectionStore.shared.load()
    }

    func server(_ id: SFTPConnection.ID?) -> SFTPConnection? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    func presentNewServer() {
        editingServer = nil
        isServerEditorPresented = true
    }

    func presentEditServer(_ connection: SFTPConnection) {
        editingServer = connection
        isServerEditorPresented = true
    }

    @discardableResult
    func saveServer(_ connection: SFTPConnection, password: String?,
                    keyPassphrase: String? = nil) -> CredentialWrite {
        // Renaming a host or user strands a pooled connection under the OLD key that nothing else reaches.
        let previous = server(connection.id)
        let outcome = SFTPConnectionStore.shared.save(connection, password: password,
                                                      keyPassphrase: keyPassphrase)
        reloadServers()
        // Pooled connections captured the old credentials, so without this they reconnect with them until restart.
        dropPooledConnections(for: connection, and: previous)
        return outcome
    }

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

    func removeServer(_ id: SFTPConnection.ID) {
        if selectedServer == id { selectedServer = nil }
        if sftpBrowserNavigation?.connectionID == id { sftpBrowserNavigation = nil }
        // Read before the store forgets it, or the removed server keeps a live authenticated connection.
        if let going = server(id) { dropPooledConnections(for: going, and: nil) }
        SFTPBrowserLocationStore.shared.removePath(for: id)
        SFTPConnectionStore.shared.remove(id)
        reloadServers()
        toastNow("Server removed")
    }

    func selectServer(_ id: SFTPConnection.ID) {
        sftpBrowserNavigation = nil
        selectedServer = id
    }

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

    /// A stale task must not erase a newer click that arrived while it was listing.
    func acknowledgeSFTPBrowserNavigation(_ requestID: UUID) {
        guard sftpBrowserNavigation?.id == requestID else { return }
        sftpBrowserNavigation = nil
    }

    func closeServerBrowser() {
        sftpBrowserNavigation = nil
        selectedServer = nil
    }

    func isServerEngaged(_ id: SFTPConnection.ID) -> Bool {
        selectedServer == id || sftpTransfers.contains { $0.connectionID == id && $0.isActive }
    }

    func disconnectServer(_ id: SFTPConnection.ID) {
        // The mirroring VoiceOver action carries no disabled state, so this guard cannot live in the view.
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
            // Re-read, don't close over the sheet's list: an upload starting meanwhile would survive cancellation.
            for transfer in self.activeTransfers(for: id) { self.cancelSFTPTransfer(transfer.id) }
            self.finishDisconnect(id)
        }
    }

    private func activeTransfers(for id: SFTPConnection.ID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.connectionID == id && $0.isActive }
    }

    private func finishDisconnect(_ id: SFTPConnection.ID) {
        if selectedServer == id { closeServerBrowser() }
        if sftpBrowserNavigation?.connectionID == id { sftpBrowserNavigation = nil }
        serverTestsInFlight.remove(id)
        osProbesInFlight.remove(id)
        toastNow("Disconnected")
    }

    func reconnectServer(_ id: SFTPConnection.ID) {
        guard server(id) != nil else { return }
        sftpBrowserNavigation = nil
        selectedServer = id
        osProbesInFlight.remove(id)
        bumpBrowserGeneration()
        toastNow("Reconnecting…")
        Task { await refreshServerStatuses() }
    }

    /// The sidebar's dot is a bare TCP connect, so a stale password still shows green; this authenticates.
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

    /// `.unavailable` counts: an unreadable pin is exactly what "Forget Host Key" exists to clear.
    func hasHostKeyRecord(_ connection: SFTPConnection) -> Bool {
        HostKeyStore.shared.lookup(host: connection.host, port: connection.port) != .none
    }

    /// Deliberately credential-free (`password: ""` skips the Keychain) — this is public fingerprint data.
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
            // Read the pin *after* the round-trip: another connection can pin during it, making "Pinned" a lie.
            HostKeyInspector.present(endpoint: endpoint,
                                     pinned: HostKeyStore.shared.lookup(host: host, port: port),
                                     live: live)
        }
    }

    /// Always confirmed: forgetting the pin drops the protection that makes a host-key swap visible.
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

    func sshURL(for connection: SFTPConnection) -> URL? {
        Self.sshURL(username: connection.username, host: connection.host, port: connection.port)
    }

    /// `URLComponents`, not interpolation: a username with `@`, `/` or a space would re-point the host half.
    nonisolated static func sshURL(username: String, host: String, port: Int) -> URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "ssh"
        if !username.isEmpty { components.user = username }
        components.host = host
        if port != 22 { components.port = port }
        return components.url
    }

    /// This leaves Goel: the external client uses its own `known_hosts`, not our pinned key.
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

    func sftpClient(for connection: SFTPConnection) -> SFTPClient? {
        SFTPSession.client(for: connection)
    }

    /// Resolve **once**: each resolution can raise its own Keychain prompt, so never add a second lookup.
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

    func sftpClientReportingFailure(for connection: SFTPConnection) -> SFTPClient? {
        let (client, failure) = sftpClientOrFailure(for: connection)
        if let failure { toastNow(failure) }
        return client
    }

    func sftpLocator(for connection: SFTPConnection, remotePath: String) -> String {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = connection.username
        components.host = connection.host
        if connection.port != 22 { components.port = connection.port }
        components.path = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        return components.string ?? "sftp://\(connection.username)@\(connection.host)\(remotePath)"
    }

    func enqueueSFTPDownload(connection: SFTPConnection, remotePath: String) {
        add(rawLines: sftpLocator(for: connection, remotePath: remotePath),
            saveDirectory: nil, priority: .normal)
    }
}
