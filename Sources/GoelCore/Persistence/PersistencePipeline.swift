import Foundation

// MARK: - PersistOp

/// A single on-disk mutation, funnelled through the serial ``PersistencePipeline``.
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

// MARK: - Error bridge

/// Forwards persistence failures off the detached writer without capturing the owning actor in
/// ``PersistencePipeline/init(store:errorHandler:)``. `onError` is set-once under a lock.
public final class PersistenceErrorHandler: @unchecked Sendable {
    /// Set-once box: sync install/snapshot never holds a lock across `await`.
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

    /// Install the failure bridge. No-op if already set (first writer wins).
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

// MARK: - Pipeline

/// Serial on-disk persistence pipeline: one ordered stream so a stale snapshot never overtakes a newer
/// one (e.g. `.finished` clobbering `.completed`). I/O is detached; ``enqueue`` is a `nonisolated` yield.
public actor PersistencePipeline {

    /// Holds the write-side continuation + worker handle outside actor isolation so ``enqueue`` stays
    /// `nonisolated`. `yield` is thread-safe; the worker Task is only mutated from ``shutdown()``.
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

        // Start the single serial worker immediately. Same ordering guarantee as
        // the old lazy-start path: stream is unbounded, empty until first yield.
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

    /// Enqueue one mutation. Sync yield — ordered when called serially from one actor.
    nonisolated public func enqueue(_ op: PersistOp) {
        state.continuation.yield(op)
    }

    /// Finish the stream and wait until every enqueued write has landed (or failed).
    public func shutdown() async {
        state.continuation.finish()
        await state.worker?.value
        state.worker = nil
    }
}
