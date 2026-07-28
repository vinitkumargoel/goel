import Foundation

// MARK: - Persistence pipeline

/// Thin enqueue façade over ``PersistencePipeline``. Stats throttle and the UI
/// warning stay on the manager; ordered disk I/O lives in the pipeline.
extension DownloadManager {

    /// The latest persistence warning, if any. Polled by the UI bridge.
    public var currentPersistenceWarning: String? { persistenceWarning }

    /// Record (and log) a persistence failure so it can be surfaced.
    func notePersistenceError(_ error: Error) {
        persistenceWarning = "Couldn’t save to disk: \(error.localizedDescription)"
        // The description can name the store's path, so it travels as a private
        // field rather than being written straight to stderr.
        GoelLog.persistence.error("Persistence failed", .detail(String(describing: error)))
    }

    /// Persist a single task. Enqueued on the serial pipeline so it can never be
    /// overtaken by an older write. Error bridge is installed once at restore.
    func persist(_ task: DownloadTask) {
        pipeline?.enqueue(.saveTask(task))
    }

    /// Persist the current settings on the serial pipeline.
    func persistSettings() {
        // The user's own choice, never the managed overlay: writing forced values back would make
        // an administrator's policy survive removal of the profile that imposed it.
        pipeline?.enqueue(.saveSettings(storedSettings))
    }

    /// Remove a persisted task on the serial pipeline.
    func persistRemoval(_ id: DownloadTask.ID) {
        pipeline?.enqueue(.deleteTask(id))
    }

    /// Archive a completed download on the serial pipeline.
    func persistHistory(_ entry: HistoryEntry) {
        pipeline?.enqueue(.saveHistory(entry))
    }

    /// Remove one archived entry on the serial pipeline.
    func persistHistoryRemoval(_ id: UUID) {
        pipeline?.enqueue(.deleteHistory(id))
    }

    /// Wipe the archive on the serial pipeline.
    func persistHistoryClear() {
        pipeline?.enqueue(.clearHistory)
    }

    /// Persist per-task speed-chart samples (keyed by task-id string) so a chart resumes after relaunch.
    /// Called on a coarse cadence: the samples are a display nicety, not queue state.
    public func persistSpeedHistory(_ history: [String: [SpeedHistoryPoint]]) {
        pipeline?.enqueue(.saveSpeedHistory(history))
    }

    /// Load the persisted per-task speed-chart samples (empty when none saved).
    /// A one-shot read at launch, mirroring how stats are restored.
    public func loadSpeedHistory() -> [String: [SpeedHistoryPoint]] {
        guard let store else { return [:] }
        return (try? store.loadSpeedHistory()) ?? [:]
    }

    /// Persist transfer statistics on the serial pipeline; progress-driven calls are throttled to
    /// ~30 s. Pass `force: true` on meaningful transitions (a completed download) to flush now.
    func persistStats(force: Bool = false) {
        guard pipeline != nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsFlush) >= 30 else { return }
        lastStatsFlush = now
        pipeline?.enqueue(.saveStats(stats))
    }
}
