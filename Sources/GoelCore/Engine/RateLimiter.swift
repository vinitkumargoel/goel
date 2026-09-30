import Foundation

/// Caps AGGREGATE bytes/sec so writers sum to the cap, not N×; per-task limits chain via `next`, never `min()`.
actor RateLimiter {
    private var bytesPerSecond: Double
    private let next: RateLimiter?
    /// Monotonic: a wall-clock step backwards (NTP, VM resume) would otherwise stall every writer for the jump.
    private let clock = ContinuousClock()
    private var drainTime: ContinuousClock.Instant
    private let rateFlag = RateFlag()

    init(bytesPerSecond: Int64, next: RateLimiter? = nil) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.next = next
        self.drainTime = ContinuousClock.now
        rateFlag.set(limited: bytesPerSecond > 0)
    }

    /// Read without an actor hop, so the hot write path skips `pace` entirely when nothing in the chain limits.
    nonisolated var isEffectivelyUnlimited: Bool {
        !rateFlag.isLimited && (next?.isEffectivelyUnlimited ?? true)
    }

    func setRate(_ bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        rateFlag.set(limited: bytesPerSecond > 0)
    }

    func pace(_ byteCount: Int) async {
        guard byteCount > 0 else { return }
        // An unlimited link must still forward: it may exist only to carry the chain to the pacer behind it.
        if bytesPerSecond > 0 {
            let now = clock.now
            // Idle gap: never bank credit for bytes that were not in flight.
            if drainTime < now { drainTime = now }
            drainTime = drainTime.advanced(by: .seconds(Double(byteCount) / bytesPerSecond))
            if drainTime > now {
                try? await clock.sleep(until: drainTime, tolerance: nil)
            }
        }
        await next?.pace(byteCount)
    }
}

private final class RateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var limited = false
    func set(limited: Bool) { lock.lock(); self.limited = limited; lock.unlock() }
    var isLimited: Bool { lock.lock(); defer { lock.unlock() }; return limited }
}
