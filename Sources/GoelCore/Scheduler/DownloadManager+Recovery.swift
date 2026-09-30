import Foundation

/// Recovery steps a failure card offers: point a download at a fresh link, move it to a folder
/// with room, or try again after a pause. Each keeps the task (and, where it is provably safe,
/// its partial file) instead of making the user add the download again.
extension DownloadManager {

    public enum SourceReplacement: Equatable, Sendable {
        /// `keepsPartial`: bytes already on disk stay; the engine still resumes from them only when
        /// the new link serves the same file (same size and ETag / Last-Modified), else it restarts at 0.
        case replaced(keepsPartial: Bool)
        case notFound
        case finished
        case busy
        case unsupportedKind
        case invalidLink
        case sameLink
        case duplicate(name: String)
    }

    /// Points a stopped HTTP(S) download at a new link. A finished download is left alone: its
    /// file is the record of the old link. The resume cursor is kept on purpose — it carries the
    /// size and validators of the partial, and ``SegmentedTransfer`` discards it (restarting from
    /// zero) unless the new link proves it serves the very same file, so a changed file can never
    /// be spliced onto the old bytes.
    public func replaceSource(_ id: DownloadTask.ID, with raw: String) async -> SourceReplacement {
        guard let current = task(id) else { return .notFound }
        guard current.status != .completed else { return .finished }
        guard !current.status.isActive, !runningSlots.contains(id) else { return .busy }
        guard current.kind == .http else { return .unsupportedKind }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = adoptInlineCredentials(trimmed, replaceExisting: true),
              case .url(let url) = source,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return .invalidLink }
        guard source.dedupKey != current.source.dedupKey else { return .sameLink }
        if let other = dedupIndex[source.dedupKey], other != id, let j = index(of: other) {
            return .duplicate(name: tasks[j].name)
        }
        // Re-resolve: `adoptInlineCredentials` may have touched the keychain, but nothing awaited.
        guard let i = index(of: id) else { return .notFound }
        let keepsPartial = tasks[i].bytesDownloaded > 0 || tasks[i].resumeData != nil
        tasks[i].source = source
        tasks[i].remoteInfo = nil
        tasks[i].connections = nil
        tasks[i].retryAttempt = nil
        // A mirror list belonged to the old link's host; a fresh link starts clean.
        tasks[i].mirrors = nil
        rebuildTaskIndex()
        if case .failed = tasks[i].status {
            reactivateFailed(at: i)
        } else {
            persist(tasks[i])
            publish()
            await refreshEngineCopy(id)
        }
        return .replaced(keepsPartial: keepsPartial)
    }

    public enum Relocation: Equatable, Sendable {
        case moved
        case notFound
        case finished
        case busy
        case sameFolder
        case unsupportedKind
        case conflict
        case changedDuringMove
        case failed(String)
    }

    /// Moves a stopped download to another folder, taking its partial file along, then retries it
    /// if it had failed. Only HTTP has a partial layout known here (one `.goelpart`), so it alone
    /// carries bytes across; any other kind may only move before it has written anything. The move
    /// never blocks the manager: across volumes the partial is COPIED off the actor while the
    /// original stays authoritative, and the switch is committed only if the task is still stopped
    /// and unchanged — otherwise the copy is thrown away and nothing changes.
    public func relocate(_ id: DownloadTask.ID, to directory: String) async -> Relocation {
        guard let snapshot = task(id) else { return .notFound }
        guard snapshot.status != .completed else { return .finished }
        guard !snapshot.status.isActive, !runningSlots.contains(id) else { return .busy }
        let target = (directory as NSString).standardizingPath
        guard target != (snapshot.saveDirectory as NSString).standardizingPath else { return .sameFolder }
        let partials = Self.partialFiles(of: snapshot)
        if snapshot.kind != .http, !partials.isEmpty || snapshot.bytesDownloaded > 0 {
            return .unsupportedKind
        }
        let moves = partials.map { source in
            (from: source, to: (target as NSString).appendingPathComponent((source as NSString).lastPathComponent))
        }
        let fm = FileManager.default
        if moves.contains(where: { fm.fileExists(atPath: $0.to) }) { return .conflict }

        let copied: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                for move in moves { try FileManager.default.copyItem(atPath: move.from, toPath: move.to) }
                return .success(())
            } catch {
                for move in moves { try? FileManager.default.removeItem(atPath: move.to) }
                return .failure(error)
            }
        }.value
        if case .failure(let error) = copied { return .failed(error.localizedDescription) }

        // Commit only if nothing touched the task while the copy ran.
        guard let i = index(of: id),
              !tasks[i].status.isActive, !runningSlots.contains(id),
              tasks[i].saveDirectory == snapshot.saveDirectory,
              tasks[i].bytesDownloaded == snapshot.bytesDownloaded,
              tasks[i].name == snapshot.name else {
            for move in moves { try? fm.removeItem(atPath: move.to) }
            return .changedDuringMove
        }
        tasks[i].saveDirectory = target
        guard tasks[i].isSavePathContained else {
            tasks[i].saveDirectory = snapshot.saveDirectory
            for move in moves { try? fm.removeItem(atPath: move.to) }
            return .failed("Path traversal blocked")
        }
        for move in moves { try? fm.removeItem(atPath: move.from) }
        if case .failed = tasks[i].status {
            reactivateFailed(at: i)
        } else {
            persist(tasks[i])
            publish()
            await refreshEngineCopy(id)
        }
        return .moved
    }

    /// The on-disk scratch a stopped, unfinished download owns: the `.goelpart`, or — for a
    /// download from before partial files — the final path itself when a resume cursor exists.
    static func partialFiles(of task: DownloadTask, fileManager fm: FileManager = .default) -> [String] {
        let part = PartialFile.path(for: task.savePath)
        if fm.fileExists(atPath: part) { return [part] }
        if task.resumeData != nil, fm.fileExists(atPath: task.savePath) { return [task.savePath] }
        return []
    }

    /// Parks a failed download and starts it again at `date` through the scheduled-start path
    /// (the same one "Start at…" uses), so it survives a relaunch and can be cancelled by resuming.
    @discardableResult
    public func retry(_ id: DownloadTask.ID, at date: Date) async -> Bool {
        guard let i = index(of: id), case .failed = tasks[i].status else { return false }
        autoRetryTasks[id]?.cancel()
        autoRetryTasks[id] = nil
        tasks[i].status = .paused
        tasks[i].scheduledAt = date
        tasks[i].retryAttempt = nil
        tasks[i].connections = nil
        clearLiveRates(id)
        persist(tasks[i])
        publish()
        armScheduledStarts()
        return true
    }
}
