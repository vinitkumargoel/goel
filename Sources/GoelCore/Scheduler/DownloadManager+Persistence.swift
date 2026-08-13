import Foundation

extension DownloadManager {

    public var currentPersistenceWarning: String? { persistenceWarning }

    /// Reads and writes fail for different reasons and send the user after different problems:
    /// "couldn't save" is misleading advice for someone whose settings were reset to defaults.
    enum PersistenceStage { case loading, saving }

    func notePersistenceError(_ error: Error, stage: PersistenceStage = .saving) {
        // The description can name the store's path, so it travels as a private field rather than straight to stderr.
        let detail = GoelLogField.detail(String(describing: error))
        switch stage {
        case .saving:
            persistenceWarning = "Couldn’t save to disk: \(error.localizedDescription)"
            GoelLog.persistence.error("Persistence failed", detail)
        case .loading:
            persistenceWarning = "Couldn’t read your saved settings and totals — they’ve been "
                + "reset to defaults for now: \(error.localizedDescription)"
            GoelLog.persistence.error("Persistence load failed", detail)
        }
    }

    /// Enqueued on the serial pipeline: a direct write could be overtaken by an older one.
    func persist(_ task: DownloadTask) {
        pipeline?.enqueue(.saveTask(task))
    }

    func persistSettings() {
        // The user's own choice, never the managed overlay: writing forced values back makes an administrator's policy survive removal of the profile that imposed it.
        pipeline?.enqueue(.saveSettings(storedSettings))
    }

    func persistRemoval(_ id: DownloadTask.ID) {
        pipeline?.enqueue(.deleteTask(id))
    }

    func persistHistory(_ entry: HistoryEntry) {
        pipeline?.enqueue(.saveHistory(entry))
    }

    func persistHistoryRemoval(_ id: UUID) {
        pipeline?.enqueue(.deleteHistory(id))
    }

    func persistHistoryClear() {
        pipeline?.enqueue(.clearHistory)
    }

    public func persistSpeedHistory(_ history: [String: [SpeedHistoryPoint]]) {
        pipeline?.enqueue(.saveSpeedHistory(history))
    }

    public func loadSpeedHistory() -> [String: [SpeedHistoryPoint]] {
        guard let store else { return [:] }
        return (try? store.loadSpeedHistory()) ?? [:]
    }

    func persistStats(force: Bool = false) {
        // Never write over totals we failed to read: the defaults in `stats` are zeros, not truth.
        guard pipeline != nil, !statsLoadFailed else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsFlush) >= 30 else { return }
        lastStatsFlush = now
        pipeline?.enqueue(.saveStats(stats))
    }
}
