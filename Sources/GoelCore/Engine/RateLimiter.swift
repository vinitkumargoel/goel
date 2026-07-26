import Foundation

// MARK: - Rate limiter

/// Shared, actor-isolated download pacer that enforces an AGGREGATE byte cap
/// across every stream that pages through it.
///
/// It reserves a slice of a virtual timeline of length `byteCount / rate` for
/// every flush. Because the timeline (`drainTime`) is shared and advanced
/// atomically before each sleep, concurrent writers queue behind one another and
/// their combined throughput converges on the cap — not `N ×` the cap. The sleep
/// happens after the bytes are already buffered, so the slowed reads exert TCP
/// backpressure on the sender. A cap of 0 means unlimited.
///
/// **Chaining.** A flush is often subject to two ceilings at once: the engine-wide
/// profile cap, which must hold in SUM across concurrent downloads, and a single
/// task's own limit, which is private to that task. They cannot be merged into one
/// `min()` — that would either leak a task's slower limit onto its siblings or let
/// each download claim the whole profile cap on its own. So a per-task limiter is
/// built in front of the engine-wide one via ``init(bytesPerSecond:next:)`` and
/// both reservations are made in series. The chain is short and acyclic, and
/// `Task.sleep` releases isolation, so a forward `pace` cannot deadlock.
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

    /// Retarget a long-lived limiter (the engine-wide pacer outlives any one
    /// download, so a profile change has to reach it in place). Bytes already
    /// reserved keep their slot on the timeline; the new rate applies from the next
    /// reservation.
    func setRate(_ bytesPerSecond: Int64) {
        self.bytesPerSecond = Double(max(0, bytesPerSecond))
    }

    /// Account for `byteCount` just delivered and sleep long enough to keep the
    /// shared rate at or below the cap. Cancellation-aware: a pause/remove during
    /// the sleep wakes it immediately (the caller's own checkCancellation reacts).
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
