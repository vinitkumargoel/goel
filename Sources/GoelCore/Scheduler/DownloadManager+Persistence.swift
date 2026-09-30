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
    /// Every full-row write carries the latest resume data, so it also settles any coalesced flush.
    func persist(_ task: DownloadTask) {
        resumeDirty.remove(task.id)
        pipeline?.enqueue(.saveTask(task))
    }

    /// Engines emit resume data about once a second per task; writing the whole row each time was ~10
    /// synced commits/s with ten downloads. Keep the newest in memory and write at most every few seconds;
    /// any status change, pause or shutdown persists the row (and so this) immediately.
    func noteResumeDataChanged(_ id: DownloadTask.ID) {
        // The first cursor goes straight to disk; only the steady stream after it is throttled.
        let now = Date()
        let last = lastResumeFlush[id] ?? .distantPast
        if now.timeIntervalSince(last) >= Self.resumeFlushInterval, let i = index(of: id) {
            lastResumeFlush[id] = now
            persist(tasks[i])
            return
        }
        resumeDirty.insert(id)
        guard resumeFlushTask == nil else { return }
        resumeFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.resumeFlushInterval * 1_000_000_000))
            await self?.flushPendingResumeData()
        }
    }

    func flushPendingResumeData() {
        resumeFlushTask?.cancel()
        resumeFlushTask = nil
        let dirty = resumeDirty
        resumeDirty.removeAll()
        // A row removed while dirty is skipped: writing it back would resurrect a deleted task.
        let now = Date()
        for id in dirty {
            guard let i = index(of: id) else { continue }
            lastResumeFlush[id] = now
            persist(tasks[i])
        }
    }

    /// Back the unreadable row up before anything can overwrite it; if even that fails, stop persisting
    /// settings for this session rather than erase the portal token, password hash, feeds and proxy.
    func noteSettingsLoadFailure(store: PersistenceStore) {
        do {
            try store.backupSettingsRow()
            postNotice(L10n.t("Your saved settings couldn’t be read, so defaults are in use. The original was kept as a backup in the database."))
        } catch {
            settingsLoadFailed = true
            GoelLog.persistence.error("Settings backup failed", .detail(String(describing: error)))
            postNotice(L10n.t("Your saved settings couldn’t be read or backed up. Changes to settings won’t be saved until Goel° restarts, so nothing overwrites them."))
        }
    }

    func persistSettings() {
        guard !settingsLoadFailed else {
            GoelLog.persistence.error("Settings not saved — the stored row couldn’t be read or backed up")
            return
        }
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
        do {
            return try store.loadSpeedHistory()
        } catch {
            GoelLog.persistence.error("Speed history load failed", .detail(String(describing: error)))
            return [:]
        }
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
