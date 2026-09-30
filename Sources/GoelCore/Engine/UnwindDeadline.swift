import Foundation

/// A real deadline on a job's exit. A task group can't do this: it waits for children that ignore
/// cancellation, and `Task.value` never returns early — so the continuation is resumed by whichever
/// of "job finished" / "timer fired" comes first, and the loser is dropped by the latch.
enum UnwindDeadline {

    /// True when `job` finished within `seconds`.
    static func wait(for job: Task<Void, Never>, seconds: TimeInterval) async -> Bool {
        let latch = Latch()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if latch.claim() { continuation.resume(returning: false) }
            }
            Task {
                await job.value
                timer.cancel()
                if latch.claim() { continuation.resume(returning: true) }
            }
        }
    }

    /// Exactly-once: a continuation resumed twice traps.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
