import Foundation

/// The user's queue order: the one the scheduler starts rows in and the list's "#" column shows.
/// Pure functions over task arrays so the manager, the list and the tests all agree on it.
public enum QueueOrder: Sendable {

    /// Where a move puts the rows it carries.
    public enum Placement: Sendable, Equatable {
        case top
        case bottom
        case before(UUID)
        case after(UUID)
    }

    /// Queue order. A row without a position sorts after every numbered one (it can only be one
    /// the restore backfill has not reached yet); ties fall back to when the row was added, then
    /// to the id so the order is total and a re-sort never shuffles equal rows.
    public static func precedes(_ a: DownloadTask, _ b: DownloadTask) -> Bool {
        let pa = a.queuePosition ?? .max
        let pb = b.queuePosition ?? .max
        if pa != pb { return pa < pb }
        if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
        return a.id.uuidString < b.id.uuidString
    }

    public static func sorted(_ tasks: [DownloadTask]) -> [DownloadTask] {
        tasks.sorted(by: precedes)
    }

    /// The position a newly added row takes: the back of the line.
    public static func nextPosition(in tasks: [DownloadTask]) -> Int {
        let highest = tasks.compactMap(\.queuePosition).max() ?? -1
        // Saturating: a hand-edited row at `Int.max` must not trap every add.
        return highest < .max ? highest + 1 : highest
    }

    /// Positions are small, non-negative counters. Anything else came from a damaged or
    /// hand-edited row and is renumbered rather than trusted.
    static let validPositions = 0..<(1 << 40)

    /// 1-based rank per row, dense even when removals left gaps in the stored positions: "#3" is
    /// the third row in line, not whatever number the row happened to be given.
    public static func ranks(_ tasks: [DownloadTask]) -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        out.reserveCapacity(tasks.count)
        for (offset, task) in sorted(tasks).enumerated() { out[task.id] = offset + 1 }
        return out
    }

    /// Numbers rows saved before positions existed, in their array order (the store loads by
    /// `addedAt`, so that is the old start order), after every row that already has one.
    public static func backfilled(_ tasks: [DownloadTask]) -> [DownloadTask] {
        let tasks = tasks.map { task in
            guard let position = task.queuePosition, !validPositions.contains(position) else { return task }
            var cleared = task
            cleared.queuePosition = nil
            return cleared
        }
        guard tasks.contains(where: { $0.queuePosition == nil }) else { return tasks }
        var next = nextPosition(in: tasks)
        return tasks.map { task in
            guard task.queuePosition == nil else { return task }
            var numbered = task
            numbered.queuePosition = next
            next += 1
            return numbered
        }
    }

    /// Returns `tasks` in their original array order with every position rewritten densely from 0,
    /// the moved rows placed as asked and keeping their relative order among themselves. An anchor
    /// that is itself being moved, or is unknown, degrades to the nearest sensible end.
    public static func moving(_ ids: [UUID], to placement: Placement, in tasks: [DownloadTask]) -> [DownloadTask] {
        let moving = Set(ids)
        guard !moving.isEmpty else { return tasks }
        let ordered = sorted(tasks)
        let carried = ordered.filter { moving.contains($0.id) }
        guard !carried.isEmpty else { return tasks }
        var rest = ordered.filter { !moving.contains($0.id) }

        let insertAt: Int
        switch placement {
        case .top:
            insertAt = 0
        case .bottom:
            insertAt = rest.count
        case .before(let anchor):
            insertAt = rest.firstIndex { $0.id == anchor } ?? rest.count
        case .after(let anchor):
            insertAt = rest.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? rest.count
        }
        rest.insert(contentsOf: carried, at: insertAt)

        var position: [UUID: Int] = [:]
        for (offset, task) in rest.enumerated() { position[task.id] = offset }
        return tasks.map { task in
            var placed = task
            placed.queuePosition = position[task.id]
            return placed
        }
    }
}
