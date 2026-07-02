import Foundation

/// The re-base ledger behind the download manager's highest-frequency path (a
/// `.progress` event fires ~10×/sec/task), lifted out of the actor as a pure
/// value type so its subtle regression rule can be tested directly.
///
/// Engines report *absolute* byte counts. To fold those into lifetime totals we
/// keep a per-task ``Mark`` (the last absolute counts already recorded) and add
/// only the delta since then. The wrinkle is regression: a retry or an
/// invalidated resume can restart the engine's absolute count *below* the
/// previous mark. We must never subtract that history from the lifetime total,
/// yet the bytes re-transferred after the restart must still count. ``fold(_:)``
/// re-bases the mark DOWN to the regressed reading (delta 0 for that step) so
/// subsequent progress records the re-transferred interval from there.
public enum StatsAccumulator {

    /// A per-task watermark of the last absolute byte counts folded into the
    /// lifetime statistics.
    public struct Mark: Equatable, Sendable {
        public var down: Int64
        public var up: Int64
        public init(down: Int64, up: Int64) {
            self.down = down
            self.up = up
        }
    }

    /// Fold a fresh absolute progress reading against the task's previous mark.
    ///
    /// - Returns: the non-negative `deltaDown`/`deltaUp` to add to the lifetime
    ///   totals, and the `newMark` to store for the next fold. On a regression
    ///   (either absolute count below the mark) the mark re-bases down to the new
    ///   reading, so the delta is never negative and history is never subtracted.
    public static func fold(previous mark: Mark, absoluteDown: Int64, absoluteUp: Int64)
        -> (deltaDown: Int64, deltaUp: Int64, newMark: Mark) {
        var rebased = mark
        if absoluteDown < rebased.down { rebased.down = absoluteDown }
        if absoluteUp < rebased.up { rebased.up = absoluteUp }
        return (absoluteDown - rebased.down,
                absoluteUp - rebased.up,
                Mark(down: absoluteDown, up: absoluteUp))
    }
}
