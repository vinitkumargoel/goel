import Foundation

// MARK: - Rate limiter

/// Actor pacer capping AGGREGATE bytes/sec: flushes reserve slices of a shared `drainTime` timeline so
/// writers sum to the cap, not N× (0 = unlimited). Per-task limits chain via `next`; `min()` would leak.
actor RateLimiter {
    private var bytesPerSecond: Double
    /// The next pacer in the chain (e.g. the engine-wide ceiling behind a per-task
    /// limit). Every paced byte is charged to it too.
    private let next: RateLimiter?
    /// Wall-clock instant by which all bytes reserved so far will have drained at
    /// the target rate.
    private var drainTime: Date

    init(bytesPerSecond: Int64, next: RateLimiter? = nil) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.next = next
        self.drainTime = Date()
    }

    /// Retarget a long-lived limiter in place (the engine-wide pacer outlives any one download).
    /// Bytes already reserved keep their timeline slot; the new rate applies from the next reservation.
    func setRate(_ bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
    }

    /// Account for `byteCount` delivered and sleep to hold the shared rate at/below the cap.
    /// Cancellation-aware: a pause/remove during the sleep wakes it immediately.
    func pace(_ byteCount: Int) async {
        guard byteCount > 0 else { return }
        // An unlimited link still forwards: this limiter may exist only to carry
        // the chain to the engine-wide pacer behind it.
        if bytesPerSecond > 0 {
            let now = Date()
            // Idle gap: never bank credit for bytes that were not in flight.
            if drainTime < now { drainTime = now }
            drainTime = drainTime.addingTimeInterval(Double(byteCount) / bytesPerSecond)
            let delay = drainTime.timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        await next?.pace(byteCount)
    }
}
