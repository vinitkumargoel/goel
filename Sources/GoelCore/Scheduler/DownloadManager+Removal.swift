import Foundation

/// What "remove and delete the files" actually did, so the UI never words an unlink as "Moved to the Trash".
public enum RemovalOutcome: Sendable, Equatable {
    /// The payload is in the Trash: recoverable.
    case trashed
    /// Unlinked: an in-progress partial, or a finished file on a volume that has no Trash.
    case deleted
    /// Something the user asked to delete is still there. The manager has already posted one notice.
    case keptOnDisk(reason: String)
    /// Nothing of this download's was on disk — or `deleteData` was false.
    case nothingToDelete
    /// A loaded torrent: libtorrent deletes its own files, asynchronously, after the handle goes.
    case handledByEngine
}

extension DownloadManager {

    /// ``DownloadQueue`` / ``RemoteBackend`` witness; use ``removeAndReport(_:deleteData:)`` to word the result.
    public func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        await removeAndReport(id, deleteData: deleteData)
    }

    /// Returns nil when no such task exists. Only the torrent engine is asked to delete data: for every other
    /// kind the manager does it, because only it knows which of the paths are the download's (see ``payloadPlan``).
    /// Pass a `hold` when the removal can be undone: a spooled .torrent then survives until the hold goes,
    /// since ``reinsert(_:)`` brings the row back with the same source.
    @discardableResult
    public func removeAndReport(_ id: DownloadTask.ID, deleteData: Bool,
                                hold: RemovalHold? = nil) async -> RemovalOutcome? {
        guard let task = task(id) else { return nil }
        let engineDeletes = task.kind == .torrent
        let handedToEngine = engineStarted.contains(id)
        if handedToEngine {
            await engine(for: task.source).remove(id, deleteData: deleteData && engineDeletes)
        }
        // A completion can land while the engine unwinds; the sweep must see it or it treats a finished file as foreign.
        let latest = self.task(id) ?? task
        clearLocalState(id, removeFromList: true)
        persistRemoval(id)
        // Before any await: a snapshot published without the row and without the hold would read as orphaned.
        if let hold { holdSpool(task.source, under: hold) }
        updatePowerAssertion()
        publish()
        schedule()
        // A portal upload's spooled .torrent is only this task's; nothing else ever cleans it up.
        if hold == nil { await discardOrphanedSpools([task.source]) }
        guard deleteData else { return .nothingToDelete }
        if engineDeletes {
            return handedToEngine ? await reportLoadedTorrent(latest) : await reportUnloadedTorrent(latest)
        }
        return await removeLeftoverPayload(latest)
    }

    /// Which paths a removal may touch. `savePath` is only the download's when it finished, or when it is a
    /// pre-`.goelpart` partial: otherwise it can be the user's own file the overwrite policy would replace
    /// only on success. Partials are unlinked; finished payloads go to the Trash. Torrents are the engine's.
    struct PayloadPlan: Equatable {
        var trash: [String] = []
        var unlink: [String] = []
    }

    static func payloadPlan(for task: DownloadTask, fileExists: (String) -> Bool) -> PayloadPlan {
        guard isSweepable(task) else { return PayloadPlan() }
        let final = task.savePath
        let completed = task.status == .completed
        switch task.kind {
        case .torrent:
            return PayloadPlan()
        case .http:
            let part = PartialFile.path(for: final)
            let legacyPartial = task.resumeData != nil && !fileExists(part)
            return PayloadPlan(trash: completed || legacyPartial ? [final] : [], unlink: [part])
        case .hls:
            // Segments live in the engine's work folder; `savePath` is only written by the final mux.
            return PayloadPlan(trash: completed ? [final] : [])
        case .ftp, .sftp:
            // These resume by appending to `savePath` itself, so an unfinished one IS the partial.
            return completed ? PayloadPlan(trash: [final]) : PayloadPlan(unlink: [final])
        }
    }

    /// Never the folder itself: a degenerate name would otherwise turn "delete file" into "delete Downloads".
    static func isSweepable(_ task: DownloadTask) -> Bool {
        let dir = (task.saveDirectory as NSString).standardizingPath
        let target = (task.savePath as NSString).standardizingPath
        return task.isSavePathContained && target != dir && !task.name.isEmpty
            && task.name != "." && task.name != ".."
    }

    struct SweepResult: Sendable, Equatable {
        var trashed = false
        var deleted = false
        var failure: String?
    }

    static func sweep(_ plan: PayloadPlan) -> SweepResult {
        let fm = FileManager()
        var result = SweepResult()
        for path in plan.unlink where fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                result.deleted = true
            } catch {
                if fm.fileExists(atPath: path) { result.failure = result.failure ?? error.localizedDescription }
            }
        }
        for path in plan.trash where fm.fileExists(atPath: path) {
            do {
                switch try RemoteTransferPrep.trashOrDelete(URL(fileURLWithPath: path)) {
                case .trashed: result.trashed = true
                case .deleted: result.deleted = true
                }
            } catch {
                if fm.fileExists(atPath: path) { result.failure = result.failure ?? error.localizedDescription }
            }
        }
        return result
    }

    /// The engine was told `deleteData: false` (or never saw a row restored at launch), so this is the only
    /// delete. Off the actor: a Trash move on a slow share must not stall every engine event.
    func removeLeftoverPayload(_ task: DownloadTask) async -> RemovalOutcome {
        let result = await Task.detached(priority: .utility) { () -> SweepResult in
            let fm = FileManager()
            return Self.sweep(Self.payloadPlan(for: task) { fm.fileExists(atPath: $0) })
        }.value
        if let failure = result.failure {
            postNotice(L10n.t("Removed “%@” from the list, but its file is still on disk.", task.name),
                       taskID: task.id)
            return .keptOnDisk(reason: failure)
        }
        if result.trashed { return .trashed }
        return result.deleted ? .deleted : .nothingToDelete
    }

    /// A torrent the engine never loaded (paused at launch) has no handle to delete through, and its folder
    /// is not ours to `rm -r` by name — say so rather than claim it went.
    /// The torrent engine trashes synchronously inside `remove`, but its failure travels as a `.failed` event to a
    /// consumer the removal just cancelled. So look: a payload still at `savePath` means the Trash refused it.
    private func reportLoadedTorrent(_ task: DownloadTask) async -> RemovalOutcome {
        let path = task.savePath
        guard Self.isSweepable(task),
              await Task.detached(priority: .utility, operation: { FileManager().fileExists(atPath: path) }).value
        else { return .handledByEngine }
        postNotice(L10n.t("Removed “%@” from the list, but its files are still on disk.", task.name),
                   taskID: task.id)
        return .keptOnDisk(reason: L10n.t("The files couldn’t be moved to the Trash."))
    }

    private func reportUnloadedTorrent(_ task: DownloadTask) async -> RemovalOutcome {
        let path = task.savePath
        guard Self.isSweepable(task),
              await Task.detached(priority: .utility, operation: { FileManager().fileExists(atPath: path) }).value
        else { return .nothingToDelete }
        postNotice(L10n.t("Removed “%@” from the list. Its files weren’t loaded, so they were left on disk.", task.name),
                   taskID: task.id)
        return .keptOnDisk(reason: L10n.t("The torrent wasn’t loaded, so its files were left on disk."))
    }

    /// Undo for a removal: the same rows come back with their ids, cursors and byte counts. Nothing the engine
    /// held survives a removal, so anything that was transferring comes back paused rather than silently
    /// restarting; queued rows rejoin the line. Rows whose id or source is already listed are skipped.
    public func reinsert(_ removed: [DownloadTask]) async {
        var added = false
        for original in removed {
            guard index(of: original.id) == nil,
                  dedupIndex[original.source.dedupKey] == nil else { continue }
            var task = original
            if task.status.isDownloadingPhase || task.status == .seeding { task.status = .paused }
            task.downloadSpeed = 0
            task.uploadSpeed = 0
            task.connectionCount = 0
            task.connections = nil
            appendTask(task)
            persist(tasks[tasks.count - 1])
            added = true
        }
        guard added else { return }
        publish()
        armScheduledStarts()
        schedule()
    }

    /// A deliberate restart from zero: the engine's own cursor must go too, since `refresh` never clears it.
    func resetEngineState(_ id: DownloadTask.ID) async {
        guard engineStarted.contains(id), let task = task(id) else { return }
        consumers[id]?.cancel()
        consumers[id] = nil
        await engine(for: task.source).remove(id, deleteData: false)
        // After the await: the next promotion must `add` afresh, not `resume` a handle that is gone.
        engineStarted.remove(id)
    }
}
