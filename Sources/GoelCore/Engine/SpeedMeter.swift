import Foundation

/// The sliding-window average behind every displayed transfer rate.
///
/// Engines measure speed over very short windows (100–200 ms), so the raw
/// `EngineEvent.progress` rates swing with every TCP burst and disk flush —
/// honest numbers, but unreadable when shown directly. This meter is fed the
/// *monotonic byte counters* instead and reports the exact average over the
/// last ``defaultWindow`` seconds: a number that moves calmly regardless of
/// how often (or how burstily) the producer emits.
///
/// One instance per transfer, recorded at whatever cadence progress arrives;
/// the window math makes the reading independent of that cadence. Value type
/// with the clock injected (like ``TransferProgressMeter``) so it is
/// deterministically testable.
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

    /// The horizon rates are averaged over: long enough to flatten burst
    /// noise, short enough that a real rate change shows within a couple of
    /// display refreshes.
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

    /// Record the latest **absolute** byte counters. A drop in either counter
    /// (or a wall-clock rewind) means the transfer restarted — the window
    /// resets so the rate never reads negative or spans two attempts.
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

    /// The average rate over the retained window, `.zero` until at least
    /// ``minimumSpan`` of history exists. The span runs to `now`, so a caller
    /// polling through a stall sees the rate decay rather than freeze.
    public func reading(at now: Date) -> Reading {
        guard let oldest = samples.first, let newest = samples.last else { return .zero }
        let span = now.timeIntervalSince(oldest.time)
        guard span >= Self.minimumSpan else { return .zero }
        return Reading(down: max(0, Double(newest.down - oldest.down) / span),
                       up: max(0, Double(newest.up - oldest.up) / span))
    }
}
