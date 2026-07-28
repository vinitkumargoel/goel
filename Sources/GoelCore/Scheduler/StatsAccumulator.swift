import Foundation

/// Engines report absolute counts; a retry regresses below the mark, so `fold` re-bases DOWN, never subtracting.
enum StatsAccumulator {

    struct Mark: Equatable, Sendable {
        var down: Int64
        var up: Int64
        init(down: Int64, up: Int64) {
            self.down = down
            self.up = up
        }
    }

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
