import Foundation

/// The resume/announce/throttle/speed accounting shared by the ``FTPEngine`` and
/// ``SFTPEngine`` transfer twins.
///
/// Both engines independently re-implemented the same subtle, drift-prone
/// arithmetic in their per-transfer state (`FTPTransferContext` / the SFTP
/// download state): announce the total exactly once, emit throttled progress on a
/// fixed window, and compute a windowed speed over the *absolute* byte offset.
/// This value type owns that math in one place, with the clock injected so it is
/// deterministically testable — the accounting that was previously reachable only
/// through a live socket.
///
/// It deliberately does **not** own the transport, the write-to-disk, the abort
/// flag, or the final completion emit — those stay per-engine (they differ by
/// C library and are unchanged). The engines call ``step(total:sofar:now:)`` from
/// inside their existing lock and emit whatever the returned ``Tick`` carries.
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

    /// Fold one transport progress report. `sofar` is the **absolute** downloaded
    /// byte count (≥ `resumeFrom`); `total` is the known total size, or 0 when the
    /// transport hasn't reported it yet. Announces the total the first time it is
    /// known and emits a progress sample once per throttle window.
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
