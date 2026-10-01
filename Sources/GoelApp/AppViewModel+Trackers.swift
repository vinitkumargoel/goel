import Foundation
import GoelCore

/// Tracker editing for a torrent's Details tab, and the Settings › BitTorrent tracker list.
extension AppViewModel {

    /// Adds every valid announce URL in `text` (one per line, or comma separated).
    func addTrackers(_ text: String, to id: DownloadTask.ID) {
        let urls = TrackerList.parse(text)
        guard !urls.isEmpty else {
            toastWarning(L10n.t("No valid tracker URLs — use udp://, http:// or https://"))
            return
        }
        Task {
            let added = await manager.addTrackers(urls, task: id)
            if added > 0 {
                toastSuccess(added == 1 ? L10n.t("Added 1 tracker") : L10n.t("Added %d trackers", added))
            } else {
                toastNow(L10n.t("Those trackers are already on this torrent"))
            }
        }
    }

    func removeTrackers(_ urls: Set<String>, from id: DownloadTask.ID) {
        guard !urls.isEmpty else { return }
        Task { await manager.removeTrackers(urls, task: id) }
    }

    func editTracker(_ old: String, to new: String, on id: DownloadTask.ID) {
        Task {
            if await !manager.editTracker(old, to: new, task: id) {
                toastWarning(L10n.t("“%@” isn’t a valid tracker URL", new))
            }
        }
    }

    /// "Refresh now" in Settings: fetches the tracker list URL and reports how many came back.
    func refreshTrackerList(from address: String? = nil) {
        Task {
            do {
                let count = try await manager.refreshTrackerList(from: address)
                toastSuccess(L10n.t("Tracker list updated · %d trackers", count))
            } catch {
                toastWarning(L10n.t("Couldn’t update the tracker list — %@", error.localizedDescription))
            }
        }
    }
}
