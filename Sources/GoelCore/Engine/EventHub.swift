import Foundation

/// Thread-safe broadcaster of `EngineEvent`s to per-task subscribers.
///
/// Held by an engine as a `nonisolated let` so both the synchronous
/// `events(for:)` and the actor-internal `emit` can reach it without crossing
/// isolation boundaries. Shared by the HTTP and HLS engines.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: [UUID: AsyncStream<EngineEvent>.Continuation]] = [:]

    func subscribe(_ id: UUID) -> AsyncStream<EngineEvent> {
        // Unbounded is required: this stream also carries NON-idempotent lifecycle
        // events (statusChanged / metadataResolved / finished / failed) that must
        // never be dropped — a dropped `.downloading` after a resume would strand
        // the task. Memory is bounded instead by throttling progress emission at
        // the source (engines emit at ~10 Hz; the manager consumes promptly).
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        let subID = UUID()
        lock.lock()
        subscribers[id, default: [:]][subID] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id]?[subID] = nil
            self.lock.unlock()
        }
        return stream
    }

    func emit(_ id: UUID, _ event: EngineEvent) {
        lock.lock()
        let continuations = subscribers[id]?.values.map { $0 } ?? []
        lock.unlock()
        for continuation in continuations { continuation.yield(event) }
    }

    func finishAll(_ id: UUID) {
        lock.lock()
        let continuations = subscribers[id]
        subscribers[id] = nil
        lock.unlock()
        continuations?.values.forEach { $0.finish() }
    }
}
