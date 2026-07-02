import Foundation

// MARK: - Scheduling

/// Promotes queued tasks into free download slots and performs the async engine
/// hand-off. Split out of ``DownloadManager`` so the queue-promotion policy lives
/// on its own; the (synchronous) cap decision stays atomic before any `await`.
extension DownloadManager {

    /// Promote queued tasks into free download slots, honouring the simultaneous
    /// cap, the metadata-resolution cap, and task priority order. The ordered
    /// promotion decision is computed purely by ``SchedulingPolicy/promotions(tasks:runningSlots:maxSimultaneousDownloads:maxMetadataResolutions:windowOpen:)``;
    /// this then applies the slot/resume/status bookkeeping synchronously (so the
    /// cap decision stays atomic) and fires the async engine calls after.
    func schedule() {
        let profile = settings.selectedProfile
        let promoted = SchedulingPolicy.promotions(
            tasks: tasks,
            runningSlots: runningSlots,
            maxSimultaneousDownloads: profile.maxSimultaneousDownloads,
            maxMetadataResolutions: profile.maxMetadataResolutions,
            windowOpen: scheduleWindowOpen
        )
        guard !promoted.isEmpty else { return }

        var launches: [(id: UUID, resume: Bool)] = []
        for id in promoted {
            runningSlots.insert(id)
            let resume = engineStarted.contains(id)
            if !resume { engineStarted.insert(id) }
            setOptimisticStatus(id)
            launches.append((id, resume))
        }

        publish()
        updatePowerAssertion()
        for launch in launches {
            Task { await self.launch(launch.id, resume: launch.resume) }
        }
        Task { await self.reapplyHTTPBudget() }
    }

    /// Reflect the imminent start in the task's status before the engine emits
    /// its own status event, so observers see the queue move immediately. A magnet
    /// without metadata starts resolving; a torrent whose payload is already
    /// complete (a paused-then-resumed seeder) goes straight back to `.seeding`
    /// rather than falsely showing `.downloading` and occupying a download slot;
    /// everything else downloads.
    private func setOptimisticStatus(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if Self.isMagnet(tasks[i].source), !tasks[i].hasMetadata {
            tasks[i].status = .requestingMetadata
        } else if tasks[i].source.kind == .torrent,
                  tasks[i].hasMetadata,
                  tasks[i].fractionCompleted >= 1.0 {
            tasks[i].status = .seeding
        } else {
            tasks[i].status = .downloading
        }
    }

    /// Perform the actual (async) engine hand-off for a promoted task.
    private func launch(_ id: UUID, resume: Bool) async {
        // The promotion may have been cancelled (paused/removed) between the
        // synchronous `schedule()` bookkeeping and this async hand-off. If so,
        // bail — and for a fresh start, undo the `engineStarted` mark so a later
        // resume re-adds the task cleanly rather than calling `engine.resume` on
        // a task the engine never received.
        guard let task = task(id), task.status != .paused, !task.status.isTerminal else {
            if !resume { engineStarted.remove(id) }
            runningSlots.remove(id)
            return
        }
        let engine = engine(for: task.source)
        // Ensure a live event subscription. On a fresh add this creates it; on a
        // resume after a terminal state (where the consumer was torn down) it
        // re-establishes it before the engine starts emitting again.
        if consumers[id] == nil { subscribe(id, to: engine) }
        if resume {
            await engine.resume(id)
        } else {
            await engine.add(task)
        }
    }

    static func isMagnet(_ source: DownloadSource) -> Bool {
        if case .magnet = source { return true }
        return false
    }
}
