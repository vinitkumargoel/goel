import Foundation

/// The queue-promotion decision as a pure function, lifted out of the
/// ``DownloadManager`` actor so it can be exercised with plain values (mirroring
/// ``AutomationCore``). Given the current tasks, the occupied slots, the profile
/// caps, and whether the download window is open, it returns the ordered list of
/// task IDs to promote — nothing more. The actor still owns the mutations that
/// follow (slot reservation, the resume flag, the optimistic status, the engine
/// hand-off); this owns only the *decision*, which is the subtle part: priority
/// order, FIFO tie-breaking, the simultaneous-download cap, and the
/// metadata-resolution cap that charges only a magnet still lacking metadata.
enum SchedulingPolicy {

    /// The ordered IDs to promote into free download slots.
    ///
    /// - Parameters:
    ///   - tasks: the full task list (only `.queued`, not-already-running tasks
    ///     are eligible).
    ///   - runningSlots: IDs currently occupying a download slot.
    ///   - maxSimultaneousDownloads: the profile's simultaneous-download cap;
    ///     `0` (or negative) means unlimited.
    ///   - maxMetadataResolutions: the profile's concurrent metadata-resolution
    ///     cap; `0` (or negative) means unlimited.
    ///   - windowOpen: whether the configured download window is currently open.
    /// - Returns: the IDs to promote, in the order they should start. Empty when
    ///   the window is closed, no slots are free, or nothing is eligible.
    static func promotions(
        tasks: [DownloadTask],
        runningSlots: Set<UUID>,
        maxSimultaneousDownloads: Int,
        maxMetadataResolutions: Int,
        windowOpen: Bool
    ) -> [UUID] {
        // Outside the configured download window nothing is promoted.
        guard windowOpen else { return [] }

        let maxDownloads = maxSimultaneousDownloads > 0 ? maxSimultaneousDownloads : .max
        let maxMetadata = maxMetadataResolutions > 0 ? maxMetadataResolutions : .max

        var freeSlots = maxDownloads - runningSlots.count
        guard freeSlots > 0 else { return [] }

        var activeMetadata = tasks.filter { $0.status == .requestingMetadata }.count

        let candidates = tasks
            .filter { $0.status == .queued && !runningSlots.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.priority != rhs.priority
                    ? lhs.priority > rhs.priority      // higher priority first
                    : lhs.addedAt < rhs.addedAt        // then FIFO
            }

        var promoted: [UUID] = []
        for task in candidates {
            guard freeSlots > 0 else { break }
            // Only a magnet that STILL lacks metadata will actually occupy a
            // metadata-resolution slot. An already-resolved (e.g. resumed) magnet
            // must not be charged against the cap — doing so would wrongly hold
            // back a fresh magnet that genuinely needs to resolve.
            let needsMetadata = isMagnet(task.source) && !task.hasMetadata
            if needsMetadata, activeMetadata >= maxMetadata { continue }

            promoted.append(task.id)
            freeSlots -= 1
            if needsMetadata { activeMetadata += 1 }
        }
        return promoted
    }

    private static func isMagnet(_ source: DownloadSource) -> Bool {
        if case .magnet = source { return true }
        return false
    }
}
