// MARK: - Connection governor

/// Adaptive per-download concurrency limiter that discovers the server's ceiling: start at the
/// requested fan-out, shrink on every 429 (Hetzner allows ~3). Monotonic — re-opening slots thrashes.
actor ConnectionGovernor {
    private var limit: Int
    private var active = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Suspends until a connection slot is free, then claims it. A cancelled caller throws
    /// `CancellationError`; without that, `pump()` would range-GET against a torn-down transfer.
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
                // Re-check under the actor: a cancellation firing after the guard must not park a
                // continuation the handler already ran past — it would never be resumed.
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

    /// Still-queued waiter: drop it and resume throwing `CancellationError` so it never opens a
    /// doomed connection. Already admitted by `pump()`: it owns the slot and will `release()` it.
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

// MARK: - Per-adapter governors

/// Per-adapter ``ConnectionGovernor``s: a 429 is per source IP, so throttling the download-wide
/// governor would starve healthy NICs. Keys fixed at init; unknown key no-ops so pump can't deadlock.
final class AdapterGovernors: Sendable {
    private let governors: [String: ConnectionGovernor]

    init(adapters: [BoundAdapter], limit: Int) {
        var map: [String: ConnectionGovernor] = [:]
        for a in adapters where map[a.bsdName] == nil {
            map[a.bsdName] = ConnectionGovernor(limit: limit)
        }
        self.governors = map
    }

    func acquire(_ bsdName: String) async throws { try await governors[bsdName]?.acquire() }
    func release(_ bsdName: String) async { await governors[bsdName]?.release() }
    func throttleDown(_ bsdName: String) async { await governors[bsdName]?.throttleDown() }
}
