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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a connection slot is free, then claims it.
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by `pump()`, which already reserved the slot on our behalf.
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
            waiter.resume()
        }
    }
}
