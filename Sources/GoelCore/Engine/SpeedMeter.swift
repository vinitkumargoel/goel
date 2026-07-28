import Foundation

public struct SpeedMeter: Sendable {

    public struct Reading: Equatable, Sendable {
        public var down: Double
        public var up: Double
        public static let zero = Reading(down: 0, up: 0)
        public init(down: Double, up: Double) {
            self.down = down
            self.up = up
        }
    }

    public static let defaultWindow: TimeInterval = 3

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

    /// Takes **absolute** counters; a drop or clock rewind resets the window so rates never go negative.
    public mutating func record(down: Int64, up: Int64 = 0, at now: Date) {
        if let last = samples.last,
           down < last.down || up < last.up || now < last.time {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(Sample(time: now, down: down, up: up))
        // Keep one sample at/behind the boundary, else the average spans less than the full window.
        let cutoff = now.addingTimeInterval(-window)
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
    }

    /// Span runs to `now`, not `newest.time` — deliberate, so a stall decays instead of freezing.
    public func reading(at now: Date) -> Reading {
        guard let oldest = samples.first, let newest = samples.last else { return .zero }
        let span = now.timeIntervalSince(oldest.time)
        guard span >= Self.minimumSpan else { return .zero }
        return Reading(down: max(0, Double(newest.down - oldest.down) / span),
                       up: max(0, Double(newest.up - oldest.up) / span))
    }
}
