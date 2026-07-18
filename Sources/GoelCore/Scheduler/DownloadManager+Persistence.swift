import Foundation

// MARK: - Persistence pipeline

/// The serial on-disk persistence pipeline. All writes funnel through one
/// ordered stream (``ensurePersistWorker()``) so a stale snapshot can never
/// overtake a newer one — e.g. a `.finished` write clobbering the authoritative
/// `.completed` write and resurrecting a done download as Paused on relaunch.
extension DownloadManager {

    /// The latest persistence warning, if any. Polled by the UI bridge.
    public var currentPersistenceWarning: String? { persistenceWarning }

    /// Record (and log) a persistence failure so it can be surfaced.
    func notePersistenceError(_ error: Error) {
        persistenceWarning = "Couldn’t save to disk: \(error.localizedDescription)"
        FileHandle.standardError.write(Data("[GoelDownloader] persistence error: \(error)\n".utf8))
    }

    /// Start the single serial persistence worker the first time it is needed.
    ///
    /// All on-disk mutations flow through one ordered stream so they are applied
    /// strictly in enqueue order. This removes the race where two independent
    /// detached writes reached GRDB's queue in an undefined order and a stale
    /// snapshot landed last — e.g. a `.finished` snapshot (still `.downloading`)
    /// overwriting the authoritative `.completed` write, which would resurface a
    /// finished download as Paused on the next launch.
    private func ensurePersistWorker() {
        guard !persistStarted, let store, let stream = persistStream else { return }
        persistStarted = true
        persistStream = nil
        persistWorker = Task.detached { [weak self] in
            for await op in stream {
                do {
                    switch op {
                    case .saveTask(let task): try store.saveTask(task)
                    case .deleteTask(let id): try store.deleteTask(id)
                    case .saveSettings(let settings): try store.saveSettings(settings)
                    case .saveStats(let stats): try store.saveStats(stats)
                    case .saveHistory(let entry): try store.saveHistoryEntry(entry)
                    case .deleteHistory(let id): try store.deleteHistoryEntry(id)
                    case .clearHistory: try store.clearHistory()
                    case .saveSpeedHistory(let history): try store.saveSpeedHistory(history)
                    }
                } catch {
                    await self?.notePersistenceError(error)
                }
            }
        }
    }

    /// Persist a single task. Enqueued on the serial pipeline (see
    /// ``ensurePersistWorker()``) so it can never be overtaken by an older write.
    func persist(_ task: DownloadTask) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveTask(task))
    }

    /// Persist the current settings on the serial pipeline.
    func persistSettings() {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveSettings(settings))
    }

    /// Remove a persisted task on the serial pipeline.
    func persistRemoval(_ id: DownloadTask.ID) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.deleteTask(id))
    }

    /// Archive a completed download on the serial pipeline.
    func persistHistory(_ entry: HistoryEntry) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveHistory(entry))
    }

    /// Remove one archived entry on the serial pipeline.
    func persistHistoryRemoval(_ id: UUID) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.deleteHistory(id))
    }

    /// Wipe the archive on the serial pipeline.
    func persistHistoryClear() {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.clearHistory)
    }

    /// Persist the per-task speed-chart samples on the serial pipeline, so a
    /// download's throughput chart resumes after relaunch instead of starting
    /// blank. Called on a coarse cadence by the UI (the samples are a display
    /// nicety, not queue state), keyed by task-id string.
    public func persistSpeedHistory(_ history: [String: [SpeedHistoryPoint]]) {
        guard store != nil else { return }
        ensurePersistWorker()
        persistContinuation?.yield(.saveSpeedHistory(history))
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
        guard store != nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsFlush) >= 30 else { return }
        lastStatsFlush = now
        ensurePersistWorker()
        persistContinuation?.yield(.saveStats(stats))
    }
}
