import Foundation

extension DownloadManager {

    func updatePowerAssertion() {
        power.setPreventSleep(shouldPreventSleep())
    }

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

        if !hasActiveDownload {
            if settings.allowSleepWhileSeeding { return false }
            if settings.dontSeedOnBattery, onBattery { return false }
            return true
        }

        // Deliberately coarser than the pause policy: any "back off on battery" opt-in releases the hold, and AutomationCore does the rest.
        if onBattery, settings.allowSleepIfResumable { return false }
        if onBattery, settings.pauseBelowBatteryThreshold { return false }
        return true
    }

    func updateWatchFolder() async {
        guard settings.btWatchFolderEnabled, !settings.btWatchFolderPath.isEmpty else {
            await folderWatch.stop()
            return
        }
        let autoStart = settings.btWatchStartWithoutConfirmation
        await folderWatch.start(path: settings.btWatchFolderPath) { [weak self] url in
            // Bind before the `Task`, not `self?.` inside: a capture list makes a *var*, which the toolchain CI builds with refuses to read from concurrent code.
            guard let self else { return }
            Task { await self.ingestWatchedTorrent(url, autoStart: autoStart) }
        }
    }

    /// Created paused rather than add-then-pause, which can lose to the scheduler's optimistic promotion.
    private func ingestWatchedTorrent(_ url: URL, autoStart: Bool) async {
        add(source: .torrentFile(url), startPaused: !autoStart)
    }

    /// Clamp to `1…8760` hours before the nanosecond conversion, which **traps** above ~5M hours — and an imported backup file can set that field.
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

    /// Relies on the timestamp format sorting lexicographically, so name order is age order.
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

    // Read-only after construction; the toolchain treats `DateFormatter` as `Sendable`, so the detached backup task may read it.
    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Multi-file torrents are scanned per file: a scanner handed a folder can pass having read none of it.
    func onDownloadCompleted(_ task: DownloadTask) {
        if settings.antivirusEnabled {
            let id = task.id
            let executable = settings.antivirusExecutablePath
            let template = settings.antivirusArgumentTemplate
            let scanner = self.scanner
            let paths = Self.scanTargets(for: task)
            // Fail CLOSED: with every declared path escaping the save directory nothing is screenable, and falling back to the folder is the "scanned one thing" hole.
            guard !paths.isEmpty else {
                GoelLog.scheduler.error("Antivirus found no screenable file", .path(task.savePath))
                recordScanVerdict(id, passed: false)
                deleteSourceTorrentIfRequested(task)
                return
            }
            // Separate a misconfigured scanner from a real detection: both end up `flagged`, but they are not the same message.
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
                // Only a *clean* file reaches auto-extract / post-download actions, else a malicious archive unpacks before the scanner vetoes it.
                if passed { await self?.runPostDownloadActions(task) }
            }
        } else {
            runPostDownloadActions(task)
        }
        deleteSourceTorrentIfRequested(task)
    }

    /// Engine-declared per-file paths are untrusted, so escapers are dropped — an empty result is a refusal, not "nothing to do".
    static func scanTargets(for task: DownloadTask) -> [String] {
        guard task.isMultiFile else { return [task.savePath] }
        return task.wantedFiles.compactMap { file in
            let path = (task.saveDirectory as NSString).appendingPathComponent(file.path)
            return PathSafety.isContained(path, within: task.saveDirectory) ? path : nil
        }
    }

    func recordScanVerdict(_ id: UUID, passed: Bool) {
        _ = mutateTask(id) { $0.scanVerdict = passed ? "clean" : "flagged" }
    }

    /// A user script goes through the same `FileScanning` port so it inherits the blocklist and the timeout.
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
                // A failing script never fails the task, but one that is missing, non-executable, ProcessSafety-vetoed or non-zero must not look like it ran.
                let ok = await scanner.scan(path: path, executablePath: executable,
                                            argumentTemplate: template)
                if !ok {
                    GoelLog.scheduler.error(
                        "Post-download script failed or could not be launched", .path(executable))
                }
            }
        }
    }

    static func extractableArchiveKind(for path: String) -> String? {
        path.lowercased().hasSuffix(".zip") ? "zip" : nil
    }

    /// Watchdog-bounded so a zip bomb can't park the task, then escapees are swept. macOS-only: no `/usr/bin/ditto` on the Linux daemon.
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
                // Must return: `waitUntilExit()` on an unlaunched `Process` is undefined on Darwin.
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

    /// Ten minutes: generous for a legitimate archive, finite for one designed never to finish.
    static let extractionTimeout: Duration = .seconds(600)

    /// Defense in depth after `ditto`: an entry resolving outside the target (e.g. a symlink to `/private/tmp`) is removed so "open extracted folder" can't be redirected.
    static func quarantineExtractedEscapees(under target: String) {
        let fm = FileManager.default
        // Whole tree, not just the top level, so a nested symlink (`sub/evil -> /etc`) is caught; the enumerator does not descend links, so an escaper is a leaf.
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

/// Holds the non-`Sendable` `Process` behind a lock so the watchdog can terminate it safely, and no-ops once it has exited.
private final class ExtractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    func timeoutKill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        guard process.isRunning else { return false }
        process.terminate()
        return true
    }
}
