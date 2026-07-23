import Foundation

/// Thread-safe broadcaster of `EngineEvent`s to per-task subscribers.
///
/// Held by an engine as a `nonisolated let` so both the synchronous
/// `events(for:)` and the actor-internal `emit` can reach it without crossing
/// isolation boundaries. Shared by every engine — including the out-of-module
/// `GoelTorrent` engine, which is why it (and the small surface it uses) is
/// `public`.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: [UUID: AsyncStream<EngineEvent>.Continuation]] = [:]

    public init() {}

    public func subscribe(_ id: UUID) -> AsyncStream<EngineEvent> {
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

    public func emit(_ id: UUID, _ event: EngineEvent) {
        lock.lock()
        let continuations = subscribers[id]?.values.map { $0 } ?? []
        lock.unlock()
        for continuation in continuations { continuation.yield(event) }
    }

    /// Emit the failure doublet an engine sends on error: the `.failed` event
    /// plus the `.statusChanged(.failed)` that drives the task to its terminal
    /// failed state. Kept in one call so the two can never drift apart.
    public func fail(_ id: UUID, _ error: DownloadError) {
        emit(id, .failed(error))
        emit(id, .statusChanged(.failed(error)))
    }

    /// Emit the success completion doublet: `.finished` then `.statusChanged(.completed)`.
    /// Kept in one call so the two can never drift apart (mirrors ``fail``).
    public func complete(_ id: UUID) {
        emit(id, .finished)
        emit(id, .statusChanged(.completed))
    }

    public func finishAll(_ id: UUID) {
        lock.lock()
        let continuations = subscribers[id]
        subscribers[id] = nil
        lock.unlock()
        continuations?.values.forEach { $0.finish() }
    }
}
