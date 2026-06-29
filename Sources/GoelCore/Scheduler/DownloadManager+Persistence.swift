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
}
