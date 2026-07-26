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
        // Deliberately coarser than the pause policy: this only decides whether to
        // hold the machine awake, so any "back off on battery" opt-in releases the
        // hold regardless of the charge level. The threshold itself is enforced by
        // ``AutomationCore``, which pauses the tasks once the level actually drops.
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
    ///
    /// The interval is clamped to `1…8760` hours (one hour to a year) before the
    /// nanosecond conversion: `UInt64(hours) * 3600 * 1_000_000_000` **traps** on
    /// overflow above roughly five million hours, and `backupIntervalHours` is
    /// one of the fields an imported backup file can set.
    func updateBackupSchedule() {
        backupTask?.cancel()
        backupTask = nil
        guard settings.backupEnabled, store != nil else { return }
        let hours = min(max(1, settings.backupIntervalHours), 8_760)
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
    ///
    /// A multi-file torrent is screened file by file, not once against its
    /// containing folder. Handing a directory to a scanner invoked as
    /// `--quiet %path%` can complete successfully having read nothing, which
    /// reported the whole payload clean and unblocked auto-extract and the
    /// post-download script. Scanning every wanted file makes a large torrent's
    /// scan N times slower; that is the correct trade for a feature the user
    /// deliberately turned on. The first failure wins, so a scan that could not
    /// be completed is a failure rather than a pass.
    func onDownloadCompleted(_ task: DownloadTask) {
        if settings.antivirusEnabled {
            let id = task.id
            let executable = settings.antivirusExecutablePath
            let template = settings.antivirusArgumentTemplate
            let scanner = self.scanner
            let paths = Self.scanTargets(for: task)
            // Fail CLOSED: a multi-file task whose every declared path escaped the
            // save directory leaves nothing screenable. Falling back to the folder
            // would be the exact "scanned one thing, called it clean" hole.
            guard !paths.isEmpty else {
                GoelLog.scheduler.error("Antivirus found no screenable file", .path(task.savePath))
                recordScanVerdict(id, passed: false)
                deleteSourceTorrentIfRequested(task)
                return
            }
            // Separate a misconfigured scanner from a real detection in the log:
            // both end up as `flagged`, but "your scanner can't be run" and
            // "your download is infected" are not the same message.
            if !ProcessSafety.isSafeExecutable(executable.trimmingCharacters(in: .whitespacesAndNewlines)) {
                GoelLog.scheduler.error(
                    "Antivirus is enabled but the configured scanner cannot be run", .path(executable))
            }
            Task.detached { [weak self] in
                var passed = true
                for path in paths {
                    if await scanner.scan(path: path, executablePath: executable,
                                          argumentTemplate: template) { continue }
                    GoelLog.scheduler.error("Antivirus scan flagged or failed", .path(path))
                    passed = false
                    break
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

    /// Every file the antivirus must screen for `task`: the single payload for a
    /// one-file download, or each wanted member of a multi-file torrent resolved
    /// under the save directory. The engine-declared per-file path is untrusted
    /// (see ``DownloadTask/primaryFilePath``), so a member that would escape the
    /// save directory is dropped rather than scanned in place — an empty result
    /// for a multi-file task is therefore a refusal, not "nothing to do".
    /// `internal` so boundary tests can drive the matrix without an engine.
    static func scanTargets(for task: DownloadTask) -> [String] {
        guard task.isMultiFile else { return [task.savePath] }
        return task.wantedFiles.compactMap { file in
            let path = (task.saveDirectory as NSString).appendingPathComponent(file.path)
            return PathSafety.isContained(path, within: task.saveDirectory) ? path : nil
        }
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
    ///
    /// Every outcome of the extraction is *stated*: an archive type the app can't
    /// unpack, a `ditto` that failed to launch, a `ditto` that timed out, and a
    /// non-zero exit each get their own log line. Previously all four looked
    /// identical to a successful extraction — nothing at all.
    func runPostDownloadActions(_ task: DownloadTask) {
        let path = task.savePath
        if settings.postDownloadExtractArchives {
            if Self.extractableArchiveKind(for: path) != nil {
                extractArchive(at: path, into: task.saveDirectory)
            } else {
                GoelLog.scheduler.error("Auto-extract skipped — unsupported archive type", .path(path))
            }
        }
        if settings.postDownloadScriptEnabled, !settings.postDownloadScriptPath.isEmpty {
            let executable = settings.postDownloadScriptPath
            let template = settings.postDownloadScriptArgs
            let scanner = self.scanner
            Task.detached {
                // The download itself succeeded, so a failing script never fails
                // the task — but a script that is missing, not executable, vetoed
                // by ``ProcessSafety`` or exiting non-zero must not look like it ran.
                let ok = await scanner.scan(path: path, executablePath: executable,
                                            argumentTemplate: template)
                if !ok {
                    GoelLog.scheduler.error(
                        "Post-download script failed or could not be launched", .path(executable))
                }
            }
        }
    }

    /// The archive kind ``runPostDownloadActions(_:)`` knows how to unpack, or
    /// `nil` when the file is not one the app can extract. Pure, so the supported
    /// set is testable without a filesystem. Only `zip` today — `ditto -x -k` is
    /// what does the work.
    static func extractableArchiveKind(for path: String) -> String? {
        path.lowercased().hasSuffix(".zip") ? "zip" : nil
    }

    /// Unpack `path` into a sibling "… extracted" folder with `ditto`, bounded by
    /// a watchdog so a zip bomb or a wedged extractor can't park the detached task
    /// forever, then sweep any entry that escaped the target folder.
    ///
    /// macOS-only: `/usr/bin/ditto` does not exist on Linux, where GoelCore also
    /// builds (the daemon). The `#else` branch says so rather than presenting a
    /// setting that quietly does nothing.
    private func extractArchive(at path: String, into directory: String) {
        #if os(macOS)
        Task.detached {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            let target = (directory as NSString)
                .appendingPathComponent((path as NSString).lastPathComponent + " extracted")
            unzip.arguments = ["-x", "-k", path, target]
            do {
                try unzip.run()
            } catch {
                // The process was never started; `waitUntilExit()` on an unlaunched
                // `Process` is undefined on Darwin, so this must return here.
                GoelLog.scheduler.error("Auto-extract failed to launch", .path(path))
                return
            }
            let gate = ExtractionGate(process: unzip)
            Task.detached {
                try? await Task.sleep(for: Self.extractionTimeout)
                if gate.timeoutKill() {
                    GoelLog.scheduler.error("Auto-extract timed out and was stopped", .path(path))
                }
            }
            unzip.waitUntilExit()
            gate.finish()
            if unzip.terminationStatus != 0 {
                GoelLog.scheduler.error("Auto-extract failed — the archive may be corrupt", .path(path))
            }
            Self.quarantineExtractedEscapees(under: target)
        }
        #else
        GoelLog.scheduler.error("Auto-extract is macOS-only and was skipped", .path(path))
        #endif
    }

    /// Hard ceiling on an extraction, mirroring ``AntivirusScanner``'s scan
    /// watchdog. Ten minutes is generous for a legitimate archive and finite for
    /// one designed to never finish.
    static let extractionTimeout: Duration = .seconds(600)

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
                GoelLog.scheduler.error("Removed extracted entry escaping the folder", .path(rel))
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

/// Owns an extraction's non-`Sendable` `Process` behind a lock so the watchdog can
/// terminate it safely, and makes the terminate a no-op once the process has
/// already exited. Mirrors ``AntivirusScanner``'s `ScanGate`, minus the
/// continuation — the extraction is awaited by `waitUntilExit()`, not resumed.
private final class ExtractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    /// Mark the extraction done, so a watchdog that fires afterwards does nothing.
    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    /// Stop a still-running extraction. Reports whether it actually killed one, so
    /// the caller only logs a timeout that happened.
    func timeoutKill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        guard process.isRunning else { return false }
        process.terminate()
        return true
    }
}
