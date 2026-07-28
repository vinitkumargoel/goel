import Foundation

public enum PersistOp: Sendable {
    case saveTask(DownloadTask)
    case deleteTask(UUID)
    case saveSettings(AppSettings)
    case saveStats(TransferStats)
    case saveHistory(HistoryEntry)
    case deleteHistory(UUID)
    case clearHistory
    case saveSpeedHistory([String: [SpeedHistoryPoint]])
}

public final class PersistenceErrorHandler: @unchecked Sendable {
    /// Sync install/snapshot: never hold this lock across an `await`.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (Error) async -> Void)?
        func install(_ h: @escaping @Sendable (Error) async -> Void) {
            lock.lock(); defer { lock.unlock() }
            if handler == nil { handler = h }
        }
        func snapshot() -> (@Sendable (Error) async -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return handler
        }
    }
    private let box = Box()

    public init() {}

    /// No-op if already set — first writer wins.
    public func install(_ handler: @escaping @Sendable (Error) async -> Void) {
        box.install(handler)
    }

    public func report(_ error: Error) async {
        if let onError = box.snapshot() {
            await onError(error)
        } else {
            GoelLog.persistence.error("Persistence failed (no error bridge installed)",
                                      .detail(String(describing: error)))
        }
    }
}

/// One ordered stream, so a stale snapshot never overtakes a newer one (`.finished` over `.completed`).
public actor PersistencePipeline {

    /// Outside actor isolation so ``enqueue`` stays `nonisolated`; `worker` is mutated only in `shutdown()`.
    private final class State: @unchecked Sendable {
        let continuation: AsyncStream<PersistOp>.Continuation
        var worker: Task<Void, Never>?

        init(continuation: AsyncStream<PersistOp>.Continuation) {
            self.continuation = continuation
        }
    }

    nonisolated private let state: State
    private let errorHandler: PersistenceErrorHandler

    public init(
        store: PersistenceStore,
        errorHandler: PersistenceErrorHandler = PersistenceErrorHandler()
    ) {
        self.errorHandler = errorHandler
        let (stream, continuation) = AsyncStream<PersistOp>.makeStream(bufferingPolicy: .unbounded)
        let state = State(continuation: continuation)
        self.state = state

        state.worker = Task.detached {
            for await op in stream {
                do {
                    switch op {
                    case .saveTask(let task): try store.saveTask(task)
                    case .deleteTask(let id): try store.deleteTask(id)
                    case .saveSettings(let settings): try store.saveSettings(settings)
                    case .saveStats(let stats): try store.saveStats(stats)
                    case .saveHistory(let entry): try store.saveHistoryEntry(entry)
                    case .deleteHistory(let id): try store.deleteHistoryEntry(id)
                    case .clearHistory: try store.clearHistory()
                    case .saveSpeedHistory(let history): try store.saveSpeedHistory(history)
                    }
                } catch {
                    await errorHandler.report(error)
                }
            }
        }
    }

    /// Ordered only when called serially from one actor.
    nonisolated public func enqueue(_ op: PersistOp) {
        state.continuation.yield(op)
    }

    public func shutdown() async {
        state.continuation.finish()
        await state.worker?.value
        state.worker = nil
    }
}
