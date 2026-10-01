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
                // Atomic: a crash mid-write must not leave a truncated backup that still counts toward retention.
                try data.write(to: URL(fileURLWithPath: file), options: .atomic)
                Self.pruneBackups(in: dir, keep: keep)
            } catch {
                // Not "couldn't save to disk": the queue itself is fine, only the backup copy failed.
                GoelLog.persistence.error("Automatic backup failed", .detail(String(describing: error)))
                await self?.postNotice(L10n.t("Couldn’t write the automatic backup of your download list: %@",
                                              error.localizedDescription))
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

    /// Gatekeeper only checks what carries `com.apple.quarantine`. A single file is flagged inline, so the flag
    /// lands before the completion is published (auto-open, extract, scripts never see it unmarked). A folder
    /// means a walk of the whole tree, which runs off the actor; `thenFinishCompletion` resumes after it.
    func markQuarantined(_ task: DownloadTask, thenFinishCompletion: Bool = false) {
        guard task.isSavePathContained else {
            if thenFinishCompletion { finishCompletion(task) }
            return
        }
        let url = URL(fileURLWithPath: task.savePath)
        let source = Self.quarantineSourceURL(task.source)
        let referrer = task.referer.flatMap { URL(string: $0) }
        guard Quarantine.isDirectoryTree(url) else {
            noteQuarantineFailures(Quarantine.mark(url, sourceURL: source, referrer: referrer), task: task)
            if thenFinishCompletion { finishCompletion(task) }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let failed = Quarantine.mark(url, sourceURL: source, referrer: referrer)
            await self?.afterQuarantineWalk(task, failed: failed, thenFinishCompletion: thenFinishCompletion)
        }
    }

    private func afterQuarantineWalk(_ task: DownloadTask, failed: Int, thenFinishCompletion: Bool) {
        noteQuarantineFailures(failed, task: task)
        // The row may have been removed during the walk: nothing left to scan or act on.
        guard thenFinishCompletion, index(of: task.id) != nil else { return }
        finishCompletion(task)
    }

    /// One notice per download, however many files refused the flag.
    private func noteQuarantineFailures(_ failed: Int, task: DownloadTask) {
        guard failed > 0 else { return }
        postNotice(L10n.t("Couldn’t mark %1$d item(s) in “%2$@” as downloaded from the internet, so macOS won’t check them before they open.",
                          failed, task.name),
                   taskID: task.id)
    }

    static func quarantineSourceURL(_ source: DownloadSource) -> URL? {
        switch source {
        case .url(let url), .hlsStream(let url): return url
        case .torrentFile(let url): return url.isFileURL ? nil : url
        case .magnet: return nil
        }
    }

    func onDownloadCompleted(_ task: DownloadTask) {
        markQuarantined(task, thenFinishCompletion: true)
    }

    /// Multi-file torrents are scanned per file: a scanner handed a folder can pass having read none of it.
    private func finishCompletion(_ task: DownloadTask) {
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
            let name = task.name
            Task.detached { [weak self] in
                // Either way it fails closed — nothing unscanned or flagged reaches extract or the script.
                var outcome = ScanResult.clean
                for path in paths {
                    outcome = await scanner.scan(path: path, executablePath: executable,
                                                 argumentTemplate: template)
                    guard outcome == .clean else {
                        GoelLog.scheduler.error("Antivirus scan flagged or failed", .path(path))
                        break
                    }
                }
                switch outcome {
                case .clean:
                    await self?.recordScanVerdict(id, passed: true)
                    await self?.runPostDownloadActions(task)
                case .infected:
                    await self?.recordScanVerdict(id, passed: false)
                case .error(let reason):
                    await self?.recordScanError(id, name: name, reason: reason)
                }
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

    /// A scanner that couldn't run or finish is not a detection: "error", or every download looks infected.
    func recordScanError(_ id: UUID, name: String, reason: String) {
        _ = mutateTask(id) { $0.scanVerdict = "error" }
        postNotice(L10n.t("“%1$@” wasn’t scanned: %2$@.", name, reason), taskID: id)
    }

    /// Sets what happens when this download finishes; `.nothing` or a half-filled choice clears it.
    public func setWhenDone(_ whenDone: WhenDone?, task id: DownloadTask.ID) async {
        _ = mutateTask(id) { $0.whenDone = whenDone?.isActionable == true ? whenDone : nil }
    }

    /// A per-download "Move to…" runs first, so extract, the global script and the per-download
    /// script all see the file where it now lives.
    func runPostDownloadActions(_ task: DownloadTask) {
        guard let done = task.whenDone, done.kind == .moveTo, done.isActionable,
              let target = Self.ruleFolder(done.target ?? "") else {
            runSettledPostDownloadActions(task)
            return
        }
        // A torrent keeps seeding from its folder; moving the payload out from under it breaks that.
        guard task.source.kind != .torrent else {
            postNotice(L10n.t("“%@” wasn’t moved: a torrent keeps seeding from where it downloaded.", task.name),
                       taskID: task.id)
            runSettledPostDownloadActions(task)
            return
        }
        let from = task.savePath, id = task.id, name = task.name
        let policy = settings.existingFileReaction
        Task.detached { [weak self] in
            let moved = Self.move(from: from, into: target, name: name, policy: policy)
            await self?.finishMove(id: id, original: task, movedName: moved, target: target)
        }
    }

    /// Nil when the move failed; the file then stays put and every other action still runs on it.
    static func move(from path: String, into directory: String, name: String, policy: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let finalName = resolveName(name, in: directory, policy: policy == "overwrite" ? "rename" : policy)
            let dest = (directory as NSString).appendingPathComponent(finalName)
            guard PathSafety.isContained(dest, within: directory) else { return nil }
            try fm.moveItem(atPath: path, toPath: dest)
            return finalName
        } catch {
            GoelLog.scheduler.error("Move after download failed", .path(path), .detail(String(describing: error)))
            return nil
        }
    }

    private func finishMove(id: UUID, original: DownloadTask, movedName: String?, target: String) {
        guard let movedName else {
            postNotice(L10n.t("Couldn’t move “%@” to the folder you chose. It’s still where it downloaded.",
                              original.name), taskID: id)
            runSettledPostDownloadActions(original)
            return
        }
        var moved = original
        moved.saveDirectory = target
        moved.name = movedName
        _ = mutateTask(id) {
            $0.saveDirectory = target
            $0.name = movedName
        }
        runSettledPostDownloadActions(moved)
    }

    /// A user script goes through the same `FileScanning` port so it inherits the blocklist and the timeout.
    func runSettledPostDownloadActions(_ task: DownloadTask) {
        let path = task.savePath
        runTaskScriptIfAny(task)
        if settings.postDownloadExtractArchives {
            if Self.extractableArchiveKind(for: path) != nil {
                extractArchive(at: path, into: task.saveDirectory, for: task)
            } else {
                GoelLog.scheduler.error("Auto-extract skipped — unsupported archive type", .path(path))
            }
        }
        if settings.postDownloadScriptEnabled, !settings.postDownloadScriptPath.isEmpty {
            let executable = settings.postDownloadScriptPath
            let template = settings.postDownloadScriptArgs
            let scanner = self.scanner
            let name = task.name, id = task.id
            Task.detached { [weak self] in
                // A failing script never fails the task, but one that is missing, non-executable, ProcessSafety-vetoed or non-zero must not look like it ran.
                let ran = await scanner.scan(path: path, executablePath: executable,
                                             argumentTemplate: template)
                if ran != .clean {
                    GoelLog.scheduler.error(
                        "Post-download script failed or could not be launched", .path(executable))
                    await self?.postNotice(
                        L10n.t("The post-download script failed or couldn’t be started for “%@”.", name),
                        taskID: id)
                }
            }
        }
    }

    /// The per-download "Run script" choice, on the same guarded path as the global script.
    private func runTaskScriptIfAny(_ task: DownloadTask) {
        guard let done = task.whenDone, done.kind == .runScript, done.isActionable,
              let executable = done.target else { return }
        let path = task.savePath, name = task.name, id = task.id
        let scanner = self.scanner
        Task.detached { [weak self] in
            let ran = await scanner.scan(path: path, executablePath: executable, argumentTemplate: "%path%")
            if ran != .clean {
                await self?.postNotice(
                    L10n.t("The script you chose for “%@” failed or couldn’t be started.", name), taskID: id)
            }
        }
    }

    /// Every kind goes through macOS's `bsdtar` (libarchive), which reads zip, tar (any compression),
    /// 7z and rar without extra tools.
    static func extractableArchiveKind(for path: String) -> String? {
        let lower = path.lowercased()
        if lower.hasSuffix(".zip") { return "zip" }
        let tarSuffixes = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst"]
        if tarSuffixes.contains(where: lower.hasSuffix) { return "tar" }
        if lower.hasSuffix(".7z") { return "7z" }
        if lower.hasSuffix(".rar") { return "rar" }
        return nil
    }

    /// Bounded by ``ArchiveExtractor``: size cap, time limit, staging folder, escapee sweep.
    /// macOS-only: the Linux daemon has no `/usr/bin/bsdtar` to rely on.
    private func extractArchive(at path: String, into directory: String, for task: DownloadTask) {
        #if os(macOS)
        let id = task.id, name = task.name
        let source = Self.quarantineSourceURL(task.source)
        let referrer = task.referer.flatMap { URL(string: $0) }
        Task.detached { [weak self] in
            let outcome = ArchiveExtractor.extract(path, into: directory)
            let notice: String?
            switch outcome {
            case .extracted(let target):
                // The archive's flag does not carry over through extraction; the unpacked files need their own.
                Quarantine.mark(URL(fileURLWithPath: target), sourceURL: source, referrer: referrer)
                notice = nil
            case .launchFailed:
                notice = L10n.t("Couldn’t unpack “%@”: the extractor didn’t start.", name)
            case .timedOut:
                notice = L10n.t("Unpacking “%@” took too long and was stopped.", name)
            case .tooLarge(let cap):
                notice = L10n.t("“%1$@” wasn’t unpacked: it would take more than %2$@ of disk space.",
                                name, cap.byteString)
            case .failed:
                notice = L10n.t("Couldn’t unpack “%@” — the archive may be damaged.", name)
            }
            if let notice {
                GoelLog.scheduler.error("Auto-extract did not complete", .path(path))
                await self?.postNotice(notice, taskID: id)
            }
        }
        #else
        GoelLog.scheduler.error("Auto-extract is macOS-only and was skipped", .path(path))
        #endif
    }

    /// Defense in depth after `bsdtar`: an entry resolving outside the target (e.g. a symlink to `/private/tmp`) is removed so "open extracted folder" can't be redirected.
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
