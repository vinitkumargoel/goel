import AppKit
import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    // MARK: - Inline credentials

    /// `https://user:pass@host/…` keeps working even though the parser strips the userinfo:
    /// the login moves to the Keychain, where the engine picks it up for that host.
    func adoptInlineCredentials(in rawLines: String, policy: InlineCredentials.Policy,
                                announce: Bool = true) {
        for found in InlineCredentials.findAll(in: rawLines) {
            let outcome = InlineCredentials.adopt(found, into: credentialStore, policy: policy)
            guard announce else { continue }
            switch outcome {
            case .stored(let host, let isTLS):
                // Basic auth only ever rides over TLS; over plain http it would be sent in the clear.
                if !isTLS {
                    toastNow(L10n.t("Saved the login for %@, but Goel° only sends logins over HTTPS", host),
                             isError: true)
                }
            case .keptExisting:
                break
            case .failed(let host):
                toastNow(L10n.t("Couldn’t save the login for %@ to your Keychain", host), isError: true)
            }
        }
    }

    // MARK: - Notifications

    func installNotificationHandlers() {
        let delegate = NotificationDelegate.shared
        delegate.suppressWhileActive = { [weak self] in self?.settings.notifyOnlyWhenInactive ?? false }
        delegate.onResponse = { [weak self] response in self?.handleNotificationResponse(response) }
    }

    func handleNotificationResponse(_ response: NotificationService.Response) {
        NSApp.activate(ignoringOtherApps: true)
        let id: DownloadTask.ID
        switch response {
        case .reveal(let taskID), .open(let taskID), .show(let taskID): id = taskID
        }
        guard let task = tasks.first(where: { $0.id == id }) else {
            return toastNow(L10n.t("That download is no longer in your list"))
        }
        selectedServer = nil
        selectOnly(id)
        switch response {
        case .reveal: revealInFinder(task)
        case .open: openFile(task)
        case .show: break
        }
    }

    // MARK: - Saved servers

    /// Off the main thread: the file read (and a slow home directory) must not delay the first frame.
    func loadServersInBackground() {
        Task { [weak self] in
            let outcome = await Task.detached { SFTPConnectionStore.shared.loadOutcome() }.value
            self?.applyServerLoad(outcome)
        }
    }

    func applyServerLoad(_ outcome: Result<[SFTPConnection], SFTPStoreError>) {
        switch outcome {
        case .success(let list):
            servers = list
            serverStoreWarning = nil
        case .failure:
            // Keep whatever is in memory: blanking the sidebar would look like the servers are gone.
            serverStoreWarning = L10n.t("Your saved servers couldn’t be read. They’re still on disk — "
                + "Goel° won’t change the file until it can read it again.")
        }
    }

    // MARK: - Database recovery

    /// Renames the unreadable database (and its journal files) so the next launch starts clean.
    /// The running session can't switch stores, so a relaunch is what completes it.
    func moveBrokenDatabaseAside() {
        guard let recovery = databaseRecovery else { return }
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = URL(fileURLWithPath: recovery.path)
        let aside = base.deletingLastPathComponent()
            .appendingPathComponent("queue.broken-\(stamp).sqlite")
        do {
            if fm.fileExists(atPath: base.path) {
                try fm.moveItem(at: base, to: aside)
            }
            for suffix in ["-wal", "-shm", "-journal"] where fm.fileExists(atPath: base.path + suffix) {
                try fm.moveItem(atPath: base.path + suffix, toPath: aside.path + suffix)
            }
        } catch {
            GoelLog.persistence.error("Couldn't move the broken database aside",
                                      .detail(String(describing: error)))
            toastNow(L10n.t("Couldn’t move the database aside: %@", error.localizedDescription),
                     isError: true)
            return
        }
        databaseRecovery = nil
        persistenceWarning = L10n.t("The old database was moved aside as “%@”. Quit and reopen Goel° to start fresh.",
                                    aside.lastPathComponent)
    }

    // MARK: - Completed downloads whose file is gone

    /// Adds the same source again. The manager replaces a completed row whose file is gone with
    /// a fresh task, so this is not refused as "already in your list".
    func downloadAgain(_ task: DownloadTask) {
        let manager = self.manager
        let source = task.source
        let directory = task.saveDirectory
        let priority = task.priority
        Task { await manager.add(source: source, saveDirectory: directory, priority: priority) }
        toastNow(L10n.t("Downloading “%@” again", task.name))
    }

    /// There is no API to repoint a row, so the chosen file is moved back to where the row expects it.
    func locateMissingFile(_ task: DownloadTask) {
        let panel = NSOpenPanel()
        panel.message = L10n.t("Find “%@”. It will be moved back to where Goel° expects it.", task.name)
        panel.prompt = L10n.t("Move Back")
        panel.canChooseFiles = task.files.count <= 1
        panel.canChooseDirectories = task.files.count > 1
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: task.saveDirectory)
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let destination = URL(fileURLWithPath: task.savePath)
        let fm = FileManager.default
        guard picked.standardizedFileURL != destination.standardizedFileURL else {
            Task { await self.manager.reconcileCompletedFiles() }
            return
        }
        guard !fm.fileExists(atPath: destination.path) else {
            toastNow(L10n.t("Something else is already at “%@”", destination.path), isError: true)
            return
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: picked, to: destination)
        } catch {
            toastNow(L10n.t("Couldn’t move “%1$@” back: %2$@", picked.lastPathComponent,
                            error.localizedDescription), isError: true)
            return
        }
        let manager = self.manager
        Task { await manager.reconcileCompletedFiles() }
        toastNow(L10n.t("Found “%@”", task.name))
    }
}
