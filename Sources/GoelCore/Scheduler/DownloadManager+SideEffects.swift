import Foundation

// MARK: - Cross-cutting side effects

/// The scheduler's side-effect integrations — power assertion, watch-folder
/// ingestion, periodic backup, and post-completion hooks. Split out of
/// ``DownloadManager`` so the queue logic stays self-contained; each runs
/// best-effort and can never stall or crash the queue.
extension DownloadManager {

    // MARK: Power management

    /// Recompute and apply the "prevent idle sleep" assertion from the current
    /// settings and active-download state. Idempotent (see ``PowerManager``).
    func updatePowerAssertion() {
        power.setPreventSleep(shouldPreventSleep())
    }

    /// The keep-awake decision in isolation: pure over the current tasks, settings
    /// and power source. `internal` so boundary tests can drive the battery/seeding
    /// matrix directly without poking IOKit.
    func shouldPreventSleep() -> Bool {
        guard settings.preventSleepWhileDownloading else { return false }

        var hasActiveDownload = false
        var hasSeeding = false
        for task in tasks {
            switch task.status {
            case .downloading, .verifying, .requestingMetadata: hasActiveDownload = true
            case .seeding: hasSeeding = true
            default: break
            }
        }
        guard hasActiveDownload || hasSeeding else { return false }

        let onBattery = power.isOnBattery

        // Seeding only (no active download): a lighter case the user can opt out of.
        if !hasActiveDownload {
            if settings.allowSleepWhileSeeding { return false }
            if settings.dontSeedOnBattery, onBattery { return false }
            return true
        }

        // Active downloads in flight. Honour the on-battery power-saving opt-outs.
        // `batteryThresholdPercent` cannot be read precisely at this layer
        // (the power port exposes only on-battery state), so these are best-effort:
        // while on battery we release the keep-awake hold when the user has asked
        // us to back off on battery.
        if onBattery, settings.allowSleepIfResumable { return false }
        if onBattery, settings.pauseBelowBatteryThreshold { return false }
        return true
    }

    // MARK: Watch folder

    /// Start or stop watching the configured folder per the BitTorrent settings.
    func updateWatchFolder() async {
        guard settings.btWatchFolderEnabled, !settings.btWatchFolderPath.isEmpty else {
            await folderWatch.stop()
            return
        }
        let autoStart = settings.btWatchStartWithoutConfirmation
        await folderWatch.start(path: settings.btWatchFolderPath) { [weak self] url in
            Task { await self?.ingestWatchedTorrent(url, autoStart: autoStart) }
        }
    }

    /// Add a `.torrent` discovered in the watch folder. `add()` queues it and the
    /// scheduler promotes it automatically (the "start without confirmation"
    /// behaviour); when confirmation is required we add it then pause it so it
    /// waits for the user to explicitly resume.
    private func ingestWatchedTorrent(_ url: URL, autoStart: Bool) async {
        let task = add(source: .torrentFile(url))
        if !autoStart {
            await pause(task.id)
        }
    }

    // MARK: Backup

    /// (Re)arm the periodic backup loop per the backup settings.
    func updateBackupSchedule() {
        backupTask?.cancel()
        backupTask = nil
        guard settings.backupEnabled, store != nil else { return }
        let hours = max(1, settings.backupIntervalHours)
        let interval = UInt64(hours) * 3600 * 1_000_000_000
        backupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.writeBackup()
            }
        }
    }

    /// Write a timestamped JSON backup of the current task list into a "Backups"
    /// subfolder of the default save directory. Off-actor so disk I/O never stalls
    /// the queue; failures are surfaced like any other persistence problem.
    private func writeBackup() async {
        guard let store else { return }
        let snapshot = tasks
        let baseDir = settings.defaultSaveDirectory
        Task.detached { [weak self] in
            do {
                let data = try store.exportTasks(snapshot)
                let dir = (baseDir as NSString).appendingPathComponent("GoelDownloader Backups")
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stamp = Self.backupStampFormatter.string(from: Date())
                let file = (dir as NSString).appendingPathComponent("backup-\(stamp).json")
                try data.write(to: URL(fileURLWithPath: file))
            } catch {
                await self?.notePersistenceError(error)
            }
        }
    }

    // Read-only after construction; the toolchain treats `DateFormatter` as
    // `Sendable`, so it's safe to read from the detached backup task.
    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: Completion side-effects

    /// React to a download reaching `.completed`: optionally screen the finished
    /// file with the configured antivirus and delete a consumed local `.torrent`.
    /// Both run off-actor and best-effort — neither can stall or crash the queue.
    func onDownloadCompleted(_ task: DownloadTask) {
        if settings.antivirusEnabled {
            let path = task.savePath
            let executable = settings.antivirusExecutablePath
            let template = settings.antivirusArgumentTemplate
            let scanner = self.scanner
            Task.detached {
                let passed = await scanner.scan(
                    path: path, executablePath: executable, argumentTemplate: template
                )
                if !passed {
                    FileHandle.standardError.write(
                        Data("[GoelDownloader] antivirus scan flagged or failed: \(path)\n".utf8)
                    )
                }
            }
        }
        deleteSourceTorrentIfRequested(task)
    }

    /// Delete the originating local `.torrent` file once its download has the full
    /// payload, when ``AppSettings/btAutoDeleteTorrent`` is on. Only local
    /// (`file:`) `.torrent` sources are touched; remote `.torrent` URLs are left
    /// alone. Harmless if already removed.
    func deleteSourceTorrentIfRequested(_ task: DownloadTask) {
        guard settings.btAutoDeleteTorrent,
              case let .torrentFile(url) = task.source,
              url.isFileURL else { return }
        let path = url.path
        Task.detached {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
