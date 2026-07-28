import Foundation

/// Caps AGGREGATE bytes/sec so writers sum to the cap, not N×; per-task limits chain via `next`, never `min()`.
actor RateLimiter {
    private var bytesPerSecond: Double
    private let next: RateLimiter?
    private var drainTime: Date

    init(bytesPerSecond: Int64, next: RateLimiter? = nil) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
        self.next = next
        self.drainTime = Date()
    }

    func setRate(_ bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
    }

    func pace(_ byteCount: Int) async {
        guard byteCount > 0 else { return }
        // An unlimited link must still forward: it may exist only to carry the chain to the pacer behind it.
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
