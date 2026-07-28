import Foundation

/// Shared resume/announce/throttle/speed math for the ``FTPEngine``/``SFTPEngine`` twins (each had its own,
/// drift-prone copy). Clock injected for determinism; transport, disk, abort and completion stay per-engine.
public struct TransferProgressMeter: Sendable {

    /// A downsampled progress window at 0.2 s — dozens of raw callbacks per second
    /// collapse to ~5 UI updates.
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

    /// What one folded progress report wants emitted. Either field may be nil.
    public struct Tick: Equatable, Sendable {
        /// The total size, present exactly once — the tick on which it is first known.
        public var announceTotal: Int64?
        /// A throttled progress sample, present only on a window boundary.
        public var progress: Progress?

        public struct Progress: Equatable, Sendable {
            public var bytes: Int64      // absolute downloaded offset
            public var speed: Double     // bytes/sec over the window, never negative
        }
    }

    /// Fold one transport report: `sofar` is the **absolute** byte count (≥ `resumeFrom`), `total` is 0
    /// until known. Announces the total the first time it's known; emits a sample per throttle window.
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
            // Guard against the first-ever window (distantPast → a huge dt) and any
            // wall-clock jump reporting a nonsense rate: those read as 0.
            let speed = (dt > 0 && dt < 3600) ? Double(sofar - lastEmitBytes) / dt : 0
            lastEmit = now
            lastEmitBytes = sofar
            progress = .init(bytes: sofar, speed: max(0, speed))
        }
        return Tick(announceTotal: announce, progress: progress)
    }

    /// The absolute byte count downloaded so far (never below the resume point).
    public var finalBytes: Int64 { max(lastSofar, resumeFrom) }
}
