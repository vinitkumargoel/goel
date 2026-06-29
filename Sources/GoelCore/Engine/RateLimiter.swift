import Foundation

// MARK: - Rate limiter

/// Shared, actor-isolated download pacer that enforces the active profile's
/// AGGREGATE byte cap across all of a download's segments.
///
/// It reserves a slice of a virtual timeline of length `byteCount / rate` for
/// every flush. Because the timeline (`drainTime`) is shared and advanced
/// atomically before each sleep, concurrent segments queue behind one another
/// and their combined throughput converges on the cap — not `N ×` the cap. The
/// sleep happens after the bytes are already buffered, so the slowed reads exert
/// TCP backpressure on the sender. One limiter is created per download attempt
/// from the profile's current cap; a mid-download profile change takes effect on
/// the next (re)start. A cap of 0 means unlimited and no limiter is created.
actor RateLimiter {
    private let bytesPerSecond: Double
    /// Wall-clock instant by which all bytes reserved so far will have drained at
    /// the target rate.
    private var drainTime: Date

    init(bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.drainTime = Date()
    }

    /// Account for `byteCount` just delivered and sleep long enough to keep the
    /// shared rate at or below the cap. Cancellation-aware: a pause/remove during
    /// the sleep wakes it immediately (the caller's own checkCancellation reacts).
    func pace(_ byteCount: Int) async {
        guard bytesPerSecond > 0, byteCount > 0 else { return }
        let now = Date()
        // Idle gap: never bank credit for bytes that were not in flight.
        if drainTime < now { drainTime = now }
        drainTime = drainTime.addingTimeInterval(Double(byteCount) / bytesPerSecond)
        let delay = drainTime.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
