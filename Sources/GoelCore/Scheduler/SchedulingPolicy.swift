import Foundation

enum SchedulingPolicy {

    /// A cap of `0` or less means unlimited, not "none".
    static func promotions(
        tasks: [DownloadTask],
        runningSlots: Set<UUID>,
        maxSimultaneousDownloads: Int,
        maxMetadataResolutions: Int,
        windowOpen: Bool
    ) -> [UUID] {
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
                    ? lhs.priority > rhs.priority
                    : lhs.addedAt < rhs.addedAt
            }

        var promoted: [UUID] = []
        for task in candidates {
            guard freeSlots > 0 else { break }
            // Only a magnet STILL lacking metadata takes a slot; a resumed one would block a real resolve.
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
