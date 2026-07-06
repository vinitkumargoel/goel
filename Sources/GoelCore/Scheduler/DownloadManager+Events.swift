import Foundation

// MARK: - Engine event ingestion

/// Subscribes to each engine's event stream and folds events back into the
/// stored task, then drives the status-transition bookkeeping (slot release,
/// completion hooks, promotion of the next queued task). Split out of
/// ``DownloadManager`` so the queue's reaction to engine events reads on its own.
extension DownloadManager {

    func subscribe(_ id: UUID, to engine: any DownloadEngine) {
        let stream = engine.events(for: id)
        consumers[id] = Task { [weak self] in
            for await event in stream {
                await self?.apply(event, to: id)
            }
        }
    }

    /// Fold a single engine event into the stored task and republish.
    private func apply(_ event: EngineEvent, to id: UUID) {
        guard let i = index(of: id) else { return }

        switch event {
        case let .metadataResolved(name, totalBytes, files):
            // Adopt the engine-resolved name (from DHT/peer metadata, Content-
            // Disposition, …) while the task still carries only its source-derived
            // placeholder — `DownloadTask.name` is never actually empty, so the old
            // `isEmpty` check was dead code and left magnets stuck on "Magnet
            // download". A user-supplied custom name (≠ the default) is preserved,
            // and the adopted name is re-sanitized as defense-in-depth.
            if !name.isEmpty, tasks[i].name == Self.defaultName(for: tasks[i].source) {
                tasks[i].name = PathSafety.sanitizedName(name, fallback: tasks[i].name)
            }
            tasks[i].totalBytes = totalBytes
            tasks[i].files = files

        case let .progress(bytesDownloaded, bytesUploaded, downloadSpeed, uploadSpeed, connectionCount):
            // Fold the byte deltas into the lifetime statistics against a per-task
            // mark. A regression (retry/invalidated resume restarting below the
            // previous count) re-bases the mark so history is never subtracted AND
            // the re-transferred bytes still count — the rule lives in
            // ``StatsAccumulator``.
            let mark = statsMarks[id]
                ?? StatsMark(down: tasks[i].bytesDownloaded, up: tasks[i].bytesUploaded)
            let folded = StatsAccumulator.fold(previous: mark,
                                               absoluteDown: bytesDownloaded, absoluteUp: bytesUploaded)
            stats.record(down: folded.deltaDown, up: folded.deltaUp)
            statsMarks[id] = folded.newMark
            persistStats()
            tasks[i].bytesDownloaded = bytesDownloaded
            tasks[i].bytesUploaded = bytesUploaded
            tasks[i].downloadSpeed = downloadSpeed
            tasks[i].uploadSpeed = uploadSpeed
            tasks[i].connectionCount = connectionCount

        case let .fileProgress(fileID, bytesCompleted):
            if let f = tasks[i].files.firstIndex(where: { $0.id == fileID }) {
                tasks[i].files[f].bytesCompleted = bytesCompleted
            }

        case let .nameResolved(name):
            // Adopt the engine's resolved name (re-sanitize as defense-in-depth;
            // it strips any path components so the save path stays contained).
            tasks[i].name = PathSafety.sanitizedName(name, fallback: tasks[i].name)

        case let .statusChanged(status):
            // Guard against a stale pre-pause event resurrecting a paused task: an
            // engine can have a "downloading"/"requesting metadata" event buffered
            // in its stream from just before it was stopped. If the manager has
            // authoritatively paused this task (it's `.paused` and no longer holds a
            // slot), that late active-phase event must not un-pause it — the user's
            // pause wins. Legitimate resumes pass through: they set `.queued` then an
            // optimistic phase + a slot before the engine's event arrives, so the
            // stored status is never `.paused` at that point.
            if Self.isDownloadingPhase(status),
               tasks[i].status == .paused,
               !runningSlots.contains(id) {
                return
            }
            tasks[i].status = status
            handleStatusTransition(id, status)

        case .finished:
            break   // the subsequent .statusChanged carries the terminal/seeding state

        case let .failed(error):
            // Same stale-echo guard as `.statusChanged`: an error an engine queued
            // just before it was stopped can still be drained after the manager has
            // authoritatively paused this task. If it's `.paused` and no longer holds
            // a slot, that late failure must not clobber the user's pause (which would
            // also block Resume, forcing a Retry).
            if tasks[i].status == .paused, !runningSlots.contains(id) {
                return
            }
            tasks[i].status = .failed(error)
            handleStatusTransition(id, .failed(error))

        case let .resumeDataUpdated(data):
            tasks[i].resumeData = data

        case let .connectionsUpdated(connections):
            tasks[i].connections = connections

        case let .swarmUpdated(peers, seeds):
            tasks[i].connectionCount = peers
            tasks[i].seedCount = seeds

        case let .trackersUpdated(trackers):
            tasks[i].trackers = trackers

        case let .piecesUpdated(pieces):
            tasks[i].pieceAvailability = pieces

        case let .infoHashResolved(hash):
            tasks[i].infoHash = hash

        case let .remoteInfoResolved(info):
            tasks[i].remoteInfo = info
        }

        // P1: persist only on meaningful transitions — never on raw progress (a
        // progress write 10×/sec/task is pure churn). `.finished` carries NO state
        // change (the following `.statusChanged` does), so persisting it would
        // write a stale `.downloading` snapshot that could land after — and clobber
        // — the authoritative terminal write; exclude it too.
        switch event {
        case .progress, .fileProgress, .finished, .connectionsUpdated, .swarmUpdated,
             .trackersUpdated, .piecesUpdated:
            break
        default:
            persist(tasks[i])
        }

        // P2: coalesce high-frequency progress snapshots; publish everything else
        // immediately so the queue visibly moves the instant status changes.
        switch event {
        case .progress, .fileProgress, .connectionsUpdated, .swarmUpdated,
             .trackersUpdated, .piecesUpdated:
            throttledPublish()
        default:
            publish()
        }
    }

    /// React to a task leaving the active-download phase: free its slot, stamp a
    /// completion date, run completion side-effects, tear down the now-useless
    /// event subscription on a terminal state, refresh the power assertion, and
    /// promote the next queued task.
    private func handleStatusTransition(_ id: UUID, _ status: DownloadStatus) {
        switch status {
        case .completed, .failed:
            runningSlots.remove(id)
            // The task is finished — stop consuming its stream so a completed
            // download doesn't leak a live consumer Task + continuation forever.
            // (Seeding keeps its subscription: it's still active.)
            consumers[id]?.cancel()
            consumers[id] = nil
            if let i = index(of: id) { tasks[i].connections = nil }
            if status == .completed, let i = index(of: id) {
                // A clean finish ends the failure streak, so the next unrelated
                // failure starts its auto-retry budget fresh.
                tasks[i].retryAttempt = nil
                if tasks[i].completedAt == nil {
                    tasks[i].completedAt = Date()
                    stats.completedCount += 1
                    persistStats(force: true)
                    // Archive the first completion. Removing the task later never
                    // touches this row — history outlives the queue.
                    persistHistory(HistoryEntry(task: tasks[i]))
                }
                onDownloadCompleted(tasks[i])
            }
            if case .failed = status { scheduleAutoRetryIfNeeded(id) }
            schedule()
        case .seeding:
            runningSlots.remove(id)
            // The payload is complete the moment seeding begins — auto-delete the
            // consumed local `.torrent` now if asked (it never reaches `.completed`
            // while it seeds).
            if let i = index(of: id) { deleteSourceTorrentIfRequested(tasks[i]) }
            schedule()
        case .paused:
            runningSlots.remove(id)
            schedule()
        default:
            break
        }
        updatePowerAssertion()
    }
}
