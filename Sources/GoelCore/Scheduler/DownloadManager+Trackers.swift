import Foundation

/// Tracker editing for one torrent, and the shared "extra trackers" list appended to new ones.
/// Every call is a no-op for a task that isn't a torrent.
extension DownloadManager {

    public enum TrackerListError: Error, LocalizedError, Equatable {
        case invalidURL
        case empty
        case fetch(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return L10n.t("Enter an http(s) address for the tracker list.")
            case .empty: return L10n.t("That address didn’t return any tracker URLs.")
            case .fetch(let message): return message
            }
        }
    }

    /// Adds valid, not-yet-present announce URLs; returns how many were new.
    @discardableResult
    public func addTrackers(_ urls: [String], task id: DownloadTask.ID) async -> Int {
        guard let task = task(id), task.source.kind == .torrent else { return 0 }
        let existing = Set((task.trackers ?? []).map { $0.url.lowercased() })
        let fresh = TrackerList.parse(urls.joined(separator: "\n"))
            .filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return 0 }
        await (engine(for: task.source) as? TorrentControlling)?.addTrackers(fresh, task: id)
        _ = mutateTask(id) { t in
            let tier = (t.trackers ?? []).map(\.tier).max().map { $0 + 1 } ?? 0
            t.trackers = (t.trackers ?? []) + fresh.map { TorrentTracker(url: $0, tier: tier) }
        }
        publish()
        return fresh.count
    }

    public func removeTrackers(_ urls: Set<String>, task id: DownloadTask.ID) async {
        guard let task = task(id), task.source.kind == .torrent else { return }
        let drop = Set(urls.map { $0.lowercased() })
        let kept = (task.trackers ?? []).filter { !drop.contains($0.url.lowercased()) }
        await (engine(for: task.source) as? TorrentControlling)?.replaceTrackers(kept, task: id)
        _ = mutateTask(id) { $0.trackers = kept }
        publish()
    }

    /// Swaps one announce URL for another in place, keeping its tier. False when `new` is invalid.
    @discardableResult
    public func editTracker(_ old: String, to new: String, task id: DownloadTask.ID) async -> Bool {
        let replacement = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TrackerList.isValidAnnounceURL(replacement),
              let task = task(id), task.source.kind == .torrent else { return false }
        var list = task.trackers ?? []
        guard let i = list.firstIndex(where: { $0.url == old }) else { return false }
        if list.contains(where: { $0.url.lowercased() == replacement.lowercased() && $0.url != old }) {
            list.remove(at: i)
        } else {
            list[i] = TorrentTracker(url: replacement, tier: list[i].tier)
        }
        await (engine(for: task.source) as? TorrentControlling)?.replaceTrackers(list, task: id)
        _ = mutateTask(id) { $0.trackers = list }
        publish()
        return true
    }

    /// Fetches ``AppSettings/extraTrackersURL`` (or `address`, which is then saved as it) and
    /// stores the list; returns its length. Passing the address avoids racing a settings write.
    @discardableResult
    public func refreshTrackerList(from address: String? = nil) async throws -> Int {
        let raw = (address ?? settings.extraTrackersURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw TrackerListError.invalidURL }
        let data: Data
        do {
            data = try await NetworkGuard.fetchChecked(url: url, proxy: Self.proxySpec(from: settings),
                                                       userAgent: settings.userAgent,
                                                       maxBytes: TrackerList.maxListBytes)
        } catch {
            let message = (error as? NetworkGuard.FetchError)?.description ?? error.localizedDescription
            throw TrackerListError.fetch(message)
        }
        // Public hosts only: this list is appended to every public torrent without review.
        let list = TrackerList.parse(String(decoding: data, as: UTF8.self), publicOnly: true)
        guard !list.isEmpty else { throw TrackerListError.empty }
        var next = settings
        next.extraTrackersURL = raw
        next.extraTrackers = Array(list.prefix(200))
        next.extraTrackersUpdatedAt = Date()
        await updateSettings(next)
        return next.extraTrackers.count
    }

    /// Daily refresh while the feature is on and a URL is set; a failed fetch keeps the old list.
    func updateTrackerListSchedule() {
        trackerListTask?.cancel()
        trackerListTask = nil
        guard settings.extraTrackersEnabled,
              !settings.extraTrackersURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        trackerListTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if TrackerList.needsRefresh(lastUpdated: await self.settings.extraTrackersUpdatedAt) {
                    _ = try? await self.refreshTrackerList()
                    return   // refreshTrackerList → updateSettings reschedules this loop
                }
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            }
        }
    }
}
