import Foundation

// MARK: - Engine event ingestion

/// Subscribes to each engine's event stream and folds events back into the stored task, then drives
/// status-transition bookkeeping (slot release, completion hooks, promotion of the next queued task).
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
            // Adopt the engine-resolved name (DHT/Content-Disposition) while the task holds only its
            // placeholder — `name` is never empty, so `isEmpty` left magnets stuck. A custom name wins.
            if !name.isEmpty, tasks[i].name == Self.defaultName(for: tasks[i].source) {
                tasks[i].name = PathSafety.sanitizedName(name, fallback: tasks[i].name)
            }
            tasks[i].totalBytes = totalBytes
            tasks[i].files = files

        case let .progress(bytesDownloaded, bytesUploaded, _, _, connectionCount):
            // Fold byte deltas into lifetime stats against a per-task mark. A regression (retry/resume
            // restarting lower) re-bases it so history is never subtracted — rule in ``StatsAccumulator``.
            let mark = statsMarks[id]
                ?? StatsMark(down: tasks[i].bytesDownloaded, up: tasks[i].bytesUploaded)
            let folded = StatsAccumulator.fold(previous: mark,
                                               absoluteDown: bytesDownloaded, absoluteUp: bytesUploaded)
            stats.record(down: folded.deltaDown, up: folded.deltaUp)
            statsMarks[id] = folded.newMark
            persistStats()
            tasks[i].bytesDownloaded = bytesDownloaded
            tasks[i].bytesUploaded = bytesUploaded
            // Stored ↓/↑ rates come from byte counters via a sliding window (``SpeedMeter``), not the
            // event's own 100–200 ms fields which swing per TCP burst. The one point speeds enter model.
            let now = Date()
            var meter = speedMeters[id] ?? SpeedMeter()
            meter.record(down: bytesDownloaded, up: bytesUploaded, at: now)
            let rate = meter.reading(at: now)
            speedMeters[id] = meter
            tasks[i].downloadSpeed = rate.down
            tasks[i].uploadSpeed = rate.up
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
            // Guard a stale pre-pause event from resurrecting a paused task: if the manager has
            // authoritatively paused (`.paused`, no slot), a late active-phase event must not un-pause.
            if Self.isDownloadingPhase(status),
               tasks[i].status == .paused,
               !runningSlots.contains(id) {
                return
            }
            tasks[i].status = status
            // A phase transferring no payload shows no rate: speeds are meter-derived (`.progress`),
            // so without this the last average lingers; dropping the meter re-ramps a fresh window.
            switch status {
            case .downloading, .seeding: break
            default:
                clearLiveRates(id)
            }
            handleStatusTransition(id, status)

        case .finished:
            break   // the subsequent .statusChanged carries the terminal/seeding state

        case let .failed(error):
            // Same stale-echo guard as `.statusChanged`: an error queued just before the engine
            // stopped must not clobber the user's pause — that would block Resume, forcing a Retry.
            if tasks[i].status == .paused, !runningSlots.contains(id) {
                return
            }
            tasks[i].status = .failed(error)
            clearLiveRates(id)
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

        // P1: persist only on meaningful transitions — never raw progress (10×/sec/task is churn).
        // `.finished` carries no state change, so it would write a stale snapshot over the terminal one.
        switch event {
        // Progress/swarm/piece chatter is high-frequency — never persist those. `.resumeDataUpdated`
        // still persists: the durable cursor + concurrent byte count would otherwise wait for pause.
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

    /// React to a task leaving the active-download phase: free its slot, stamp a completion date, run
    /// completion side-effects, drop the subscription if terminal, refresh power, promote the next task.
    private func handleStatusTransition(_ id: UUID, _ status: DownloadStatus) {
        switch status {
        case .completed, .failed:
            runningSlots.remove(id)
            // Finished — stop consuming its stream so a completed download doesn't leak a live
            // consumer Task + continuation forever. (Seeding keeps its subscription: still active.)
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
                    recordAudit(.completed, task: tasks[i])
                }
                onDownloadCompleted(tasks[i])
            }
            if case .failed = status {
                if let i = index(of: id) { recordAudit(.failed, task: tasks[i]) }
                scheduleAutoRetryIfNeeded(id)
            }
            schedule()
        case .seeding:
            runningSlots.remove(id)
            // The payload is complete the moment seeding begins — auto-delete the consumed local
            // `.torrent` now if asked (it never reaches `.completed` while it seeds).
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
