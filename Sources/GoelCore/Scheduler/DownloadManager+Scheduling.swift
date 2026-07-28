import Foundation

extension DownloadManager {

    /// Slot/status bookkeeping must stay synchronous (no `await`) so the cap decision is atomic.
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

    /// A complete torrent must go straight to `.seeding`, else it shows `.downloading` and holds a slot.
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

    private func launch(_ id: UUID, resume: Bool) async {
        // A cancelled promotion must undo `engineStarted`, or a later resume hits a never-added task.
        guard let task = task(id), task.status != .paused, !task.status.isTerminal else {
            if !resume { engineStarted.remove(id) }
            runningSlots.remove(id)
            return
        }
        let engine = engine(for: task.source)
        // A terminal state tore the consumer down; re-subscribe before the engine emits again.
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
