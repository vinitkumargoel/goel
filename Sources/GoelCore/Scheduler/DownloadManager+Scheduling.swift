import Foundation

// MARK: - Scheduling

/// Promotes queued tasks into free download slots and performs the async engine hand-off; the
/// synchronous cap decision stays atomic before any `await`.
extension DownloadManager {

    /// Promote queued tasks honouring the simultaneous cap, metadata-resolution cap and priority order.
    /// ``SchedulingPolicy`` decides the order; slot/status bookkeeping is synchronous so the cap is atomic.
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

    /// Set status before the engine's own event so observers see the queue move. An already-complete
    /// torrent goes straight to `.seeding` rather than falsely showing `.downloading` and holding a slot.
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
        // The promotion may have been cancelled between `schedule()` and this hand-off; a fresh start
        // must undo `engineStarted`, or a later resume calls `engine.resume` on a task never added.
        guard let task = task(id), task.status != .paused, !task.status.isTerminal else {
            if !resume { engineStarted.remove(id) }
            runningSlots.remove(id)
            return
        }
        let engine = engine(for: task.source)
        // Ensure a live event subscription: a resume after a terminal state tore the consumer down,
        // so it must be re-established before the engine starts emitting again.
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
