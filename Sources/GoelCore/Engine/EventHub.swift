import Foundation

final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: [UUID: AsyncStream<EngineEvent>.Continuation]] = [:]

    func subscribe(_ id: UUID) -> AsyncStream<EngineEvent> {
        // Unbounded is required: dropping a lifecycle event — a `.downloading` after resume — strands the task.
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

    func fail(_ id: UUID, _ error: DownloadError) {
        emit(id, .failed(error))
        emit(id, .statusChanged(.failed(error)))
    }

    func complete(_ id: UUID) {
        emit(id, .finished)
        emit(id, .statusChanged(.completed))
    }

    func finishAll(_ id: UUID) {
        lock.lock()
        let continuations = subscribers[id]
        subscribers[id] = nil
        lock.unlock()
        continuations?.values.forEach { $0.finish() }
    }
}
