import Foundation
import GoelCore

/// The main `WindowGroup`'s scene id. `openWindow` is the only way to build a window once the last
/// one is closed, and it can only address a group that declares an id.
enum MainWindowID {
    static let value = "main"
    static let history = "history"
    static let player = "player"
}

/// What "In progress" lists: running rows first, then waiting ones, capped so the popover stays
/// short — but counted in full, so the header and the "N more" row tell the truth.
struct MenuBarQueue {
    static let maxListedRows = 8

    let listed: [DownloadTask]
    let total: Int
    /// Where "N more" lands: Active when every hidden row is running, else the whole list.
    let hiddenFilter: SidebarFilter

    var hiddenCount: Int { total - listed.count }

    init(tasks: [DownloadTask], limit: Int = Self.maxListedRows) {
        let active = tasks.filter { $0.status.isActive }
        let pending = tasks.filter { !$0.status.isActive && !$0.status.isTerminal }
        let all = active + pending
        listed = Array(all.prefix(max(0, limit)))
        total = all.count
        hiddenFilter = all.dropFirst(listed.count).allSatisfy { $0.status.isActive } ? .active : .all
    }
}

/// What "Just finished" lists: the newest few downloads completed in the last day whose file
/// is still there to open.
struct MenuBarJustFinished {
    static let limit = 3
    static let window: TimeInterval = 24 * 60 * 60

    let shown: [DownloadTask]

    init(tasks: [DownloadTask], now: Date = Date(), limit: Int = Self.limit) {
        let cutoff = now.addingTimeInterval(-Self.window)
        shown = Array(tasks
            .filter { task in
                guard task.status == .completed, !task.isFileMissing,
                      let done = task.completedAt else { return false }
                return done >= cutoff && done <= now.addingTimeInterval(60)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(max(0, limit)))
    }
}

/// Which failures the menu bar lists: the newest few, plus how many there are in all.
struct MenuBarAttention {
    static let limit = 3

    let shown: [DownloadTask]
    let total: Int

    /// One pass over the queue, keeping only the newest `limit` failures in a small sorted buffer:
    /// the menu redraws often and a full sort of every failure was wasted on three rows.
    init(tasks: [DownloadTask], limit: Int = Self.limit) {
        var count = 0
        var newest: [DownloadTask] = []
        newest.reserveCapacity(limit + 1)
        for task in tasks where task.status.isFailed {
            count += 1
            guard limit > 0 else { continue }
            if newest.count == limit, let last = newest.last, task.addedAt <= last.addedAt { continue }
            let slot = newest.firstIndex { task.addedAt > $0.addedAt } ?? newest.endIndex
            newest.insert(task, at: slot)
            if newest.count > limit { newest.removeLast() }
        }
        total = count
        shown = newest
    }
}
