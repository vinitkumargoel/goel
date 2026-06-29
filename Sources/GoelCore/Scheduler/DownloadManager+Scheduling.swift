import Foundation

// MARK: - Scheduling

/// Promotes queued tasks into free download slots and performs the async engine
/// hand-off. Split out of ``DownloadManager`` so the queue-promotion policy lives
/// on its own; the (synchronous) cap decision stays atomic before any `await`.
extension DownloadManager {

    /// Promote queued tasks into free download slots, honouring the simultaneous
    /// cap, the metadata-resolution cap, and task priority order. All bookkeeping
    /// is done synchronously so the cap decision is atomic; the (async) engine
    /// calls are then fired without holding up the decision.
    func schedule() {
        let profile = settings.selectedProfile
        let maxDownloads = profile.maxSimultaneousDownloads > 0 ? profile.maxSimultaneousDownloads : .max
        let maxMetadata = profile.maxMetadataResolutions > 0 ? profile.maxMetadataResolutions : .max

        var freeSlots = maxDownloads - runningSlots.count
        guard freeSlots > 0 else { return }

        var activeMetadata = tasks.filter { $0.status == .requestingMetadata }.count

        let candidates = tasks
            .filter { $0.status == .queued && !runningSlots.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.priority != rhs.priority
                    ? lhs.priority > rhs.priority      // higher priority first
                    : lhs.addedAt < rhs.addedAt        // then FIFO
            }

        var launches: [(id: UUID, resume: Bool)] = []
        for task in candidates {
            guard freeSlots > 0 else { break }
            // Only a magnet that STILL lacks metadata will actually occupy a
            // metadata-resolution slot. An already-resolved (e.g. resumed) magnet
            // must not be charged against the cap — doing so would wrongly hold
            // back a fresh magnet that genuinely needs to resolve.
            let needsMetadata = Self.isMagnet(task.source) && !task.hasMetadata
            if needsMetadata, activeMetadata >= maxMetadata { continue }

            runningSlots.insert(task.id)
            let resume = engineStarted.contains(task.id)
            if !resume { engineStarted.insert(task.id) }
            setOptimisticStatus(task.id)
            launches.append((task.id, resume))
            freeSlots -= 1
            if needsMetadata { activeMetadata += 1 }
        }

        guard !launches.isEmpty else { return }
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
