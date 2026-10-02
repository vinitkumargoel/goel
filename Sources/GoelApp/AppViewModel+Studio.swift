import Foundation
import GoelCore

/// What the Studio redesign added to the view model, kept out of `AppViewModel.swift`: the web
/// portal's own theme, and the production init split off the designated
/// `init(system:opened:manager:settings:)` so the DEBUG snapshot harness can build a model with an
/// in-memory store. The store opening moves with the init, the one place that calls it.
@MainActor
extension AppViewModel {

    /// The web portal's theme. Deliberately independent of ``appearanceMode``.
    var remoteTheme: RemotePortalTheme {
        get { RemotePortalTheme(storedValue: settings.remoteTheme) }
        set { update { $0.remoteTheme = newValue.storedValue } }
    }

    /// Production: opens the queue database in Application Support and builds the real engines.
    /// Nothing starts until ``start()``.
    convenience init(system: SystemActions = LiveSystemActions()) {
        let opened = Self.makeStore()
        self.init(system: system, opened: opened, manager: DownloadManager(store: opened.store))
    }

    private static func makeStore() -> OpenedStore {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            GoelLog.persistence.error("No Application Support folder for the download database")
            return temporaryStore(reason: L10n.t("no Application Support folder"), recovery: nil)
        }
        let appDir = dir.appendingPathComponent("GoelDownloader", isDirectory: true)
        let path = appDir.appendingPathComponent("queue.sqlite").path
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            return OpenedStore(store: try PersistenceStore(path: path))
        } catch {
            // The reason is what tells "locked by another copy" from "corrupt" from "newer version".
            GoelLog.persistence.error("Couldn't open the download database",
                                      .detail(String(describing: error)))
            let reason = error.localizedDescription
            // Moving the file aside fixes a damaged database only; for "locked" or "newer version"
            // it would hide the user's queue behind an empty one.
            let recovery = PersistenceStore.isCorruption(error)
                ? DatabaseRecovery(path: path, reason: reason) : nil
            return temporaryStore(reason: reason, recovery: recovery)
        }
    }

    private static func temporaryStore(reason: String, recovery: DatabaseRecovery?) -> OpenedStore {
        do {
            let warning = L10n.t("Couldn’t open the database (%@) — downloads won’t survive relaunch.", reason)
            return OpenedStore(store: try PersistenceStore(), warning: warning, recovery: recovery)
        } catch {
            GoelLog.persistence.error("Couldn't open even a temporary database",
                                      .detail(String(describing: error)))
            return OpenedStore(store: nil,
                               warning: L10n.t("Couldn’t open the database (%@) — nothing you add will be saved.",
                                               reason),
                               recovery: recovery)
        }
    }
}
