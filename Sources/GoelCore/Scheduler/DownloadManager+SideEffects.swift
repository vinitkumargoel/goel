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
    /// behaviour); when confirmation is required it is created paused so it
    /// waits for the user to explicitly resume (created-paused, not
    /// add-then-pause, which can lose to the optimistic promotion).
    private func ingestWatchedTorrent(_ url: URL, autoStart: Bool) async {
        add(source: .torrentFile(url), startPaused: !autoStart)
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
    /// subfolder of the default save directory, then prune the oldest backups
    /// beyond ``AppSettings/backupKeepCount``. Off-actor so disk I/O never stalls
    /// the queue; failures are surfaced like any other persistence problem.
    private func writeBackup() async {
        guard let store else { return }
        let snapshot = tasks
        let baseDir = settings.defaultSaveDirectory
        let keep = max(1, settings.backupKeepCount)
        Task.detached { [weak self] in
            do {
                let data = try store.exportTasks(snapshot)
                let dir = (baseDir as NSString).appendingPathComponent("GoelDownloader Backups")
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let stamp = Self.backupStampFormatter.string(from: Date())
                let file = (dir as NSString).appendingPathComponent("backup-\(stamp).json")
                try data.write(to: URL(fileURLWithPath: file))
                Self.pruneBackups(in: dir, keep: keep)
            } catch {
                await self?.notePersistenceError(error)
            }
        }
    }

    /// Delete the oldest `backup-*.json` files beyond `keep`. The timestamp
    /// format sorts lexicographically, so name order is age order. Best-effort:
    /// a prune failure never surfaces (the new backup itself was written).
    static func pruneBackups(in dir: String, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let backups = names
            .filter { $0.hasPrefix("backup-") && $0.hasSuffix(".json") }
            .sorted()
        guard backups.count > keep else { return }
        for name in backups.prefix(backups.count - keep) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
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
    /// file with the configured antivirus, run the user's post-download actions,
    /// and delete a consumed local `.torrent`. All run off-actor and best-effort
    /// — none can stall or crash the queue.
    func onDownloadCompleted(_ task: DownloadTask) {
        if settings.antivirusEnabled {
            let id = task.id
            let path = task.savePath
            let executable = settings.antivirusExecutablePath
            let template = settings.antivirusArgumentTemplate
            let scanner = self.scanner
            Task.detached { [weak self] in
                let passed = await scanner.scan(
                    path: path, executablePath: executable, argumentTemplate: template
                )
                if !passed {
                    FileHandle.standardError.write(
                        Data("[GoelDownloader] antivirus scan flagged or failed: \(path)\n".utf8)
                    )
                }
                await self?.recordScanVerdict(id, passed: passed)
                // Only hand a *clean* file to the auto-extract / post-download
                // script actions. With antivirus enabled these are held until the
                // scan finishes and skipped entirely on a flagged/failed verdict —
                // otherwise a malicious archive would be unpacked (or piped to the
                // user's script) before the scanner ever got to veto it.
                if passed { await self?.runPostDownloadActions(task) }
            }
        } else {
            runPostDownloadActions(task)
        }
        deleteSourceTorrentIfRequested(task)
    }

    /// Fold the antivirus result back into the task so the verdict survives
    /// relaunch and the UI can badge a flagged file.
    func recordScanVerdict(_ id: UUID, passed: Bool) {
        _ = mutateTask(id) { $0.scanVerdict = passed ? "clean" : "flagged" }
    }

    // MARK: Post-download actions

    /// Run the configured post-completion actions: auto-extract recognised
    /// archives and/or hand the file to a user script. Both detached and
    /// best-effort; the script inherits the antivirus scanner's interpreter
    /// blocklist and timeout by running through the same `FileScanning` port.
    func runPostDownloadActions(_ task: DownloadTask) {
        let path = task.savePath
        if settings.postDownloadExtractArchives, path.lowercased().hasSuffix(".zip") {
            let directory = task.saveDirectory
            Task.detached {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                let target = (directory as NSString)
                    .appendingPathComponent((path as NSString).lastPathComponent + " extracted")
                unzip.arguments = ["-x", "-k", path, target]
                try? unzip.run()
                unzip.waitUntilExit()
                Self.quarantineExtractedEscapees(under: target)
            }
        }
        if settings.postDownloadScriptEnabled, !settings.postDownloadScriptPath.isEmpty {
            let executable = settings.postDownloadScriptPath
            let template = settings.postDownloadScriptArgs
            let scanner = self.scanner
            Task.detached {
                _ = await scanner.scan(path: path, executablePath: executable,
                                       argumentTemplate: template)
            }
        }
    }

    /// Defense in depth after `ditto` extraction: `ditto` already contains archive
    /// traversal and rejects symlink escapes, but if any extracted entry resolves
    /// outside the target folder (e.g. a symlink to `/private/tmp`), remove it so a
    /// later "open extracted folder" action can't be redirected out of the download
    /// area. A no-op on a well-behaved archive.
    static func quarantineExtractedEscapees(under target: String) {
        let fm = FileManager.default
        // Walk the whole tree, not just the top level, so a symlink nested inside an
        // extracted subdirectory (`sub/evil -> /etc`) is also caught. The enumerator
        // does not descend through symlinks, so an escaping link is reported as a
        // leaf entry and removed before anything can be written/opened through it.
        guard let en = fm.enumerator(atPath: target) else { return }
        for case let rel as String in en {
            let full = (target as NSString).appendingPathComponent(rel)
            if !PathSafety.isContained(full, within: target) {
                try? fm.removeItem(atPath: full)
                en.skipDescendants()
                FileHandle.standardError.write(Data(
                    "[GoelDownloader] removed extracted entry escaping the folder: \(rel)\n".utf8))
            }
        }
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
