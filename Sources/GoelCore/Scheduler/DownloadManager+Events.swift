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
            if tasks[i].name.isEmpty { tasks[i].name = name }
            tasks[i].totalBytes = totalBytes
            tasks[i].files = files

        case let .progress(bytesDownloaded, bytesUploaded, downloadSpeed, uploadSpeed, connectionCount):
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
            tasks[i].name = DownloadTask.sanitizedName(name, fallback: tasks[i].name)

        case let .statusChanged(status):
            tasks[i].status = status
            handleStatusTransition(id, status)

        case .finished:
            break   // the subsequent .statusChanged carries the terminal/seeding state

        case let .failed(error):
            tasks[i].status = .failed(error)
            handleStatusTransition(id, .failed(error))

        case let .resumeDataUpdated(data):
            tasks[i].resumeData = data
        }

        // P1: persist only on meaningful transitions — never on raw progress (a
        // progress write 10×/sec/task is pure churn). `.finished` carries NO state
        // change (the following `.statusChanged` does), so persisting it would
        // write a stale `.downloading` snapshot that could land after — and clobber
        // — the authoritative terminal write; exclude it too.
        switch event {
        case .progress, .fileProgress, .finished:
            break
        default:
            persist(tasks[i])
        }

        // P2: coalesce high-frequency progress snapshots; publish everything else
        // immediately so the queue visibly moves the instant status changes.
        switch event {
        case .progress, .fileProgress:
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
            if status == .completed, let i = index(of: id) {
                if tasks[i].completedAt == nil { tasks[i].completedAt = Date() }
                onDownloadCompleted(tasks[i])
            }
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
