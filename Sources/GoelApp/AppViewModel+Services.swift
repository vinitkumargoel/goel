import AppKit
import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    // MARK: - Fetch errors

    /// Words for a failed guarded fetch: `String(describing:)` showed users a Swift enum dump
    /// (`transport("…")`, `Error Domain=NSURLErrorDomain Code=-1003 …`).
    nonisolated static func fetchFailureMessage(_ error: Error) -> String {
        (error as? NetworkGuard.FetchError)?.description ?? error.localizedDescription
    }

    // MARK: - Notifications

    /// Called once the first snapshot is in: a click buffered at cold launch names a task that only
    /// exists in the list from then on.
    func installNotificationHandlers() {
        let delegate = NotificationDelegate.shared
        delegate.suppressWhileActive = { [weak self] in self?.settings.notifyOnlyWhenInactive ?? false }
        delegate.setResponseHandler { [weak self] response in self?.handleNotificationResponse(response) }
    }

    func handleNotificationResponse(_ response: NotificationService.Response) {
        let id: DownloadTask.ID
        switch response {
        case .cancelAutoShutdown:
            autoShutdownCountdown.cancel()
            return
        case .showAutoShutdown:
            MainWindowPresenter.activate()
            return
        case .show(let taskID):
            // Menu-bar-only: there may be no window to bring forward, so build one.
            MainWindowPresenter.activate()
            id = taskID
        case .reveal(let taskID), .open(let taskID):
            NSApp.activate(ignoringOtherApps: true)
            id = taskID
        }
        guard let task = tasks.first(where: { $0.id == id }) else {
            toastNow(L10n.t("That download is no longer in your list"))
            return
        }
        selectedServer = nil
        selectOnly(id)
        switch response {
        case .reveal: revealInFinder(task)
        case .open: openFile(task)
        case .show, .cancelAutoShutdown, .showAutoShutdown: break
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
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = URL(fileURLWithPath: recovery.path)
        let aside = base.deletingLastPathComponent()
            .appendingPathComponent("queue.broken-\(stamp).sqlite")
        do {
            try Self.moveDatabaseFiles(from: base.path, to: aside.path)
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

    /// One `rename(2)` per file, journals first and the database last, rolled back on any failure:
    /// a `-wal` left behind would be replayed into the fresh database next launch. The copies
    /// hold the whole queue (cookies included), so they are made owner-only.
    nonisolated static func moveDatabaseFiles(from path: String, to aside: String) throws {
        let fm = FileManager()
        var moved: [(from: String, to: String)] = []
        do {
            for suffix in ["-wal", "-shm", "-journal", ""] where fm.fileExists(atPath: path + suffix) {
                guard rename(path + suffix, aside + suffix) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                moved.append((path + suffix, aside + suffix))
                chmod(aside + suffix, 0o600)
            }
        } catch {
            for step in moved.reversed() { _ = rename(step.to, step.from) }
            throw error
        }
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
