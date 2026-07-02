// MARK: - Connection governor

/// Adaptive per-download concurrency limiter (decreasing).
///
/// Segmented downloads want many parallel connections for speed, but many
/// servers cap concurrent connections per client and answer the excess with
/// `429 Too Many Requests` (Hetzner admits only ~3). A fixed fan-out is wrong
/// either way: too low wastes bandwidth on permissive servers, too high gets
/// throttled on strict ones — and we cannot know the ceiling in advance.
///
/// So we *discover* it: start at the requested fan-out and shrink the ceiling
/// on every 429 (`throttleDown`). On a permissive server no 429s ever arrive
/// and the limit stays wide open; on a strict server it converges down to what
/// the server actually allows, so waiting segments simply queue instead of
/// hammering the server with doomed requests.
///
/// The limit is deliberately *monotonically decreasing* for the lifetime of a
/// download. Re-opening slots after a clean segment was tried and removed: it
/// pushes the limit back above the server's true ceiling, producing a fresh
/// 429, producing a re-open — a thrash that can exhaust a segment's retry
/// budget on a strict server. Re-probing belongs to a future, slower control
/// loop, not the hot path. The throughput cost is negligible because a
/// rate-limited server is the bottleneck regardless of how we slice it.
actor ConnectionGovernor {
    private var limit: Int
    private var active = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a connection slot is free, then claims it.
    ///
    /// Honours task cancellation: a caller whose `Task` is cancelled — before it
    /// queues, or while parked waiting for a slot — throws `CancellationError`
    /// instead of being granted a slot and opening a doomed request. Without this,
    /// a segment queued here when its sibling permanently fails (which cancels the
    /// whole task group) would still be resumed by `pump()` and issue a fresh range
    /// GET against an already-torn-down transfer.
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Re-check under the actor: a cancellation that fired between the
                // guard above and here must not park a continuation the handler has
                // already run past (it would then never be resumed).
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append((id: id, continuation: cont))
                }
            }
            // Resumed by `pump()`, which already reserved the slot on our behalf.
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Cancellation fired for a parked waiter: if it is still queued, drop it and
    /// resume it throwing `CancellationError` so it aborts instead of opening a
    /// doomed connection. If it is no longer queued, `pump()` already admitted it
    /// (reserving a slot) and the caller now owns that slot and will `release()` it
    /// on its own cancellation-driven exit — so there is nothing to do here.
    private func cancelWaiter(_ id: Int) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Returns a slot and admits the next waiter if there is room.
    func release() {
        active = max(0, active - 1)
        pump()
    }

    /// The server signalled rate-limiting: lower the ceiling (floor of 1).
    func throttleDown() {
        if limit > 1 { limit -= 1 }
    }

    private func pump() {
        while active < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            active += 1                 // reserve on the waiter's behalf
            waiter.continuation.resume()
        }
    }
}
