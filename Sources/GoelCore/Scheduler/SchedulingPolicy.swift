import Foundation

/// The queue-promotion decision as a pure function, lifted out of the ``DownloadManager`` actor so it
/// is testable: priority order, FIFO ties, the simultaneous cap, the metadata cap. Mutations stay there.
enum SchedulingPolicy {

    /// The IDs to promote into free slots, in start order — only `.queued`, not-already-running tasks;
    /// caps of `0` or less mean unlimited. Empty when the window is closed, no slot is free, or none eligible.
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
            // Only a magnet that STILL lacks metadata occupies a resolution slot; charging an
            // already-resolved (resumed) magnet would wrongly hold back one that needs to resolve.
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
