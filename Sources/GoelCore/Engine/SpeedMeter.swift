import Foundation

/// Sliding-window average behind every displayed transfer rate: fed *monotonic byte counters*, not the
/// jittery 100–200 ms `EngineEvent.progress` rates, and averaged over ``defaultWindow`` seconds.
public struct SpeedMeter: Sendable {

    /// A ↓/↑ rate pair in bytes/sec. Single-direction transfers (SFTP browser
    /// uploads/downloads) use the `down` channel and ignore `up`.
    public struct Reading: Equatable, Sendable {
        public var down: Double
        public var up: Double
        public static let zero = Reading(down: 0, up: 0)
        public init(down: Double, up: Double) {
            self.down = down
            self.up = up
        }
    }

    /// Averaging horizon: long enough to flatten burst noise, short enough that a real rate
    /// change shows within a couple of display refreshes.
    public static let defaultWindow: TimeInterval = 3

    /// Below this much elapsed history a rate is not yet meaningful — report
    /// zero rather than extrapolate a single burst into a headline number.
    static let minimumSpan: TimeInterval = 0.5

    private struct Sample: Sendable {
        var time: Date
        var down: Int64
        var up: Int64
    }

    private let window: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = SpeedMeter.defaultWindow) {
        self.window = window
    }

    /// Record the latest **absolute** byte counters. A counter drop or wall-clock rewind means a
    /// restart — the window resets so the rate never reads negative or spans two attempts.
    public mutating func record(down: Int64, up: Int64 = 0, at now: Date) {
        if let last = samples.last,
           down < last.down || up < last.up || now < last.time {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(Sample(time: now, down: down, up: up))
        // Trim to the window, always keeping one sample at/behind the boundary
        // so the average spans the full window once enough history exists.
        let cutoff = now.addingTimeInterval(-window)
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
    }

    /// Average rate over the retained window; `.zero` until ``minimumSpan`` of history exists. The span
    /// runs to `now`, so a caller polling through a stall sees the rate decay rather than freeze.
    public func reading(at now: Date) -> Reading {
        guard let oldest = samples.first, let newest = samples.last else { return .zero }
        let span = now.timeIntervalSince(oldest.time)
        guard span >= Self.minimumSpan else { return .zero }
        return Reading(down: max(0, Double(newest.down - oldest.down) / span),
                       up: max(0, Double(newest.up - oldest.up) / span))
    }
}
