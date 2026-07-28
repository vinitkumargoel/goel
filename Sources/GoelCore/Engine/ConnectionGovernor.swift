/// Adaptive per-download concurrency: shrink on every 429 (Hetzner allows ~3), never re-open slots — that thrashes.
actor ConnectionGovernor {
    private var limit: Int
    private var active = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// A cancelled caller must throw `CancellationError`; otherwise `pump()` range-GETs a torn-down transfer.
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
                // Re-check under the actor: a cancellation racing past the handler would park a continuation nobody resumes.
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

    /// Only still-queued waiters are dropped; one already admitted by `pump()` owns its slot and will `release()` it.
    private func cancelWaiter(_ id: Int) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        active = max(0, active - 1)
        pump()
    }

    func throttleDown() {
        if limit > 1 { limit -= 1 }
    }

    private func pump() {
        while active < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            active += 1
            waiter.continuation.resume()
        }
    }
}

/// A 429 is per source IP: throttling one download-wide governor would starve healthy NICs; unknown keys no-op rather than deadlock.
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
