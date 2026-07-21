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
        FileHandle.standardError.write(Data("[GoelDownloader] persistence error: \(error)\n".utf8))
    }

    /// Persist a single task. Enqueued on the serial pipeline so it can never be
    /// overtaken by an older write.
    func persist(_ task: DownloadTask) {
        installPersistErrorBridge()
        pipeline?.enqueue(.saveTask(task))
    }

    /// Persist the current settings on the serial pipeline.
    func persistSettings() {
        installPersistErrorBridge()
        pipeline?.enqueue(.saveSettings(settings))
    }

    /// Remove a persisted task on the serial pipeline.
    func persistRemoval(_ id: DownloadTask.ID) {
        installPersistErrorBridge()
        pipeline?.enqueue(.deleteTask(id))
    }

    /// Archive a completed download on the serial pipeline.
    func persistHistory(_ entry: HistoryEntry) {
        installPersistErrorBridge()
        pipeline?.enqueue(.saveHistory(entry))
    }

    /// Remove one archived entry on the serial pipeline.
    func persistHistoryRemoval(_ id: UUID) {
        installPersistErrorBridge()
        pipeline?.enqueue(.deleteHistory(id))
    }

    /// Wipe the archive on the serial pipeline.
    func persistHistoryClear() {
        installPersistErrorBridge()
        pipeline?.enqueue(.clearHistory)
    }

    /// Persist the per-task speed-chart samples on the serial pipeline, so a
    /// download's throughput chart resumes after relaunch instead of starting
    /// blank. Called on a coarse cadence by the UI (the samples are a display
    /// nicety, not queue state), keyed by task-id string.
    public func persistSpeedHistory(_ history: [String: [SpeedHistoryPoint]]) {
        installPersistErrorBridge()
        pipeline?.enqueue(.saveSpeedHistory(history))
    }

    /// Load the persisted per-task speed-chart samples (empty when none saved).
    /// A one-shot read at launch, mirroring how stats are restored.
    public func loadSpeedHistory() -> [String: [SpeedHistoryPoint]] {
        guard let store else { return [:] }
        return (try? store.loadSpeedHistory()) ?? [:]
    }

    /// Persist the transfer statistics on the serial pipeline. Progress-driven
    /// calls are throttled to ~30 s of churn; pass `force: true` on meaningful
    /// transitions (a completed download) to flush immediately.
    func persistStats(force: Bool = false) {
        guard pipeline != nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsFlush) >= 30 else { return }
        lastStatsFlush = now
        installPersistErrorBridge()
        pipeline?.enqueue(.saveStats(stats))
    }
}
