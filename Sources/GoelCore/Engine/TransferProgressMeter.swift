import Foundation

public struct TransferProgressMeter: Sendable {

    /// 0.2 s downsampling window: dozens of raw callbacks per second collapse to ~5 UI updates.
    public static let defaultThrottle: TimeInterval = 0.2

    private let resumeFrom: Int64
    private let throttle: TimeInterval
    private var lastSofar: Int64
    private var announcedTotal: Int64 = 0
    private var lastEmit: Date = .distantPast
    private var lastEmitBytes: Int64

    public init(resumeFrom: Int64, throttle: TimeInterval = TransferProgressMeter.defaultThrottle) {
        self.resumeFrom = resumeFrom
        self.throttle = throttle
        self.lastSofar = resumeFrom
        self.lastEmitBytes = resumeFrom
    }

    public struct Tick: Equatable, Sendable {
        public var announceTotal: Int64?
        public var progress: Progress?

        public struct Progress: Equatable, Sendable {
            public var bytes: Int64      // absolute downloaded offset
            public var speed: Double
        }
    }

    /// `sofar` is the **absolute** byte count (≥ `resumeFrom`), not a delta; `total` is 0 until known.
    public mutating func step(total: Int64, sofar: Int64, now: Date) -> Tick {
        lastSofar = sofar
        var announce: Int64?
        if total > 0, announcedTotal != total {
            announcedTotal = total
            announce = total
        }
        var progress: Tick.Progress?
        let dt = now.timeIntervalSince(lastEmit)
        if dt > throttle {
            // The first window (distantPast → a huge dt) and any wall-clock jump would report a nonsense rate; those read as 0.
            let speed = (dt > 0 && dt < 3600) ? Double(sofar - lastEmitBytes) / dt : 0
            lastEmit = now
            lastEmitBytes = sofar
            progress = .init(bytes: sofar, speed: max(0, speed))
        }
        return Tick(announceTotal: announce, progress: progress)
    }

    public var finalBytes: Int64 { max(lastSofar, resumeFrom) }
}
