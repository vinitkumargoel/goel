import Foundation

extension DownloadManager {

    func subscribe(_ id: UUID, to engine: any DownloadEngine) {
        let stream = engine.events(for: id)
        consumers[id] = Task { [weak self] in
            for await event in stream {
                await self?.apply(event, to: id)
            }
        }
    }

    private func apply(_ event: EngineEvent, to id: UUID) {
        guard let i = index(of: id) else { return }

        switch event {
        case let .metadataResolved(name, totalBytes, files):
            // Compare against the placeholder, not `isEmpty`: `name` is never empty, which left magnets stuck.
            if !name.isEmpty, tasks[i].name == Self.defaultName(for: tasks[i].source) {
                tasks[i].name = PathSafety.sanitizedName(name, fallback: tasks[i].name)
            }
            tasks[i].totalBytes = totalBytes
            tasks[i].files = files

        case let .progress(bytesDownloaded, bytesUploaded, _, _, connectionCount):
            // A regression (retry/resume restarting lower) re-bases the mark so history is never subtracted.
            let mark = statsMarks[id]
                ?? StatsMark(down: tasks[i].bytesDownloaded, up: tasks[i].bytesUploaded)
            let folded = StatsAccumulator.fold(previous: mark,
                                               absoluteDown: bytesDownloaded, absoluteUp: bytesUploaded)
            stats.record(down: folded.deltaDown, up: folded.deltaUp)
            statsMarks[id] = folded.newMark
            persistStats()
            tasks[i].bytesDownloaded = bytesDownloaded
            tasks[i].bytesUploaded = bytesUploaded
            // Rates come from the sliding window, not the event's own fields, which swing per TCP burst.
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
            // Re-sanitize as defense-in-depth: it strips path components so the save path stays contained.
            tasks[i].name = PathSafety.sanitizedName(name, fallback: tasks[i].name)

        case let .statusChanged(status):
            // A stale pre-pause event must not resurrect a task the manager authoritatively paused.
            if Self.isDownloadingPhase(status),
               tasks[i].status == .paused,
               !runningSlots.contains(id) {
                return
            }
            tasks[i].status = status
            // Speeds are meter-derived, so without this the last average lingers on a non-transferring phase.
            switch status {
            case .downloading, .seeding: break
            default:
                clearLiveRates(id)
            }
            handleStatusTransition(id, status)

        case .finished:
            break   // the subsequent .statusChanged carries the terminal/seeding state

        case let .failed(error):
            // An error queued just before the engine stopped must not clobber the user's pause and block Resume.
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

        // `.finished` would write a stale snapshot over the terminal one; `.resumeDataUpdated` must still persist.
        switch event {
        case .progress, .fileProgress, .finished, .connectionsUpdated, .swarmUpdated,
             .trackersUpdated, .piecesUpdated:
            break
        default:
            persist(tasks[i])
        }

        switch event {
        case .progress, .fileProgress, .connectionsUpdated, .swarmUpdated,
             .trackersUpdated, .piecesUpdated:
            throttledPublish()
        default:
            publish()
        }
    }

    private func handleStatusTransition(_ id: UUID, _ status: DownloadStatus) {
        switch status {
        case .completed, .failed:
            runningSlots.remove(id)
            // Stop consuming, or a completed download leaks its consumer Task and continuation forever.
            consumers[id]?.cancel()
            consumers[id] = nil
            if let i = index(of: id) { tasks[i].connections = nil }
            if status == .completed, let i = index(of: id) {
                tasks[i].retryAttempt = nil
                if tasks[i].completedAt == nil {
                    tasks[i].completedAt = Date()
                    stats.completedCount += 1
                    persistStats(force: true)
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
            // Must happen here: a seeding task never reaches `.completed`, so the cleanup would never run.
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
