import Foundation

/// Re-base ledger for the manager's hottest path (~10 `.progress`/sec/task): engines report *absolute* counts, so a
/// per-task ``Mark`` adds only deltas. A retry can regress below the mark, so ``fold(_:)`` re-bases DOWN, never subtracting.
enum StatsAccumulator {

    /// A per-task watermark of the last absolute byte counts folded into the
    /// lifetime statistics.
    struct Mark: Equatable, Sendable {
        var down: Int64
        var up: Int64
        init(down: Int64, up: Int64) {
            self.down = down
            self.up = up
        }
    }

    /// Fold a fresh absolute progress reading against the task's previous mark. - Returns: non-negative `deltaDown`/
    /// `deltaUp` plus the `newMark`; a regression re-bases the mark down, so history is never subtracted.
    static func fold(previous mark: Mark, absoluteDown: Int64, absoluteUp: Int64)
        -> (deltaDown: Int64, deltaUp: Int64, newMark: Mark) {
        var rebased = mark
        if absoluteDown < rebased.down { rebased.down = absoluteDown }
        if absoluteUp < rebased.up { rebased.up = absoluteUp }
        return (absoluteDown - rebased.down,
                absoluteUp - rebased.up,
                Mark(down: absoluteDown, up: absoluteUp))
    }
}
