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

/// Forwards persistence failures off the detached writer without capturing the
/// owning actor in ``PersistencePipeline/init(store:errorHandler:)``.
///
/// `DownloadManager` installs a handler that points at
/// ``DownloadManager/notePersistenceError(_:)`` once `self` is fully formed.
public final class PersistenceErrorHandler: @unchecked Sendable {
    public var onError: (@Sendable (Error) async -> Void)?
    public init() {}

    public func report(_ error: Error) async {
        if let onError {
            await onError(error)
        } else {
            FileHandle.standardError.write(
                Data("[GoelDownloader] persistence error: \(error)\n".utf8)
            )
        }
    }
}

// MARK: - Pipeline

/// Serial on-disk persistence pipeline. All writes funnel through one ordered
/// stream so a stale snapshot can never overtake a newer one — e.g. a
/// `.finished` write clobbering the authoritative `.completed` write and
/// resurrecting a done download as Paused on relaunch.
///
/// Disk I/O runs on a detached task (never on the caller's actor). ``enqueue``
/// is `nonisolated` and only yields onto an `AsyncStream` continuation (thread-
/// safe), so a caller actor can fire writes without `await` and still preserve
/// enqueue order. ``shutdown()`` finishes the stream and awaits drain.
public actor PersistencePipeline {

    /// Holds the write-side continuation + worker handle outside actor isolation
    /// so ``enqueue`` can stay `nonisolated` (sync yield, ordered from one actor).
    ///
    /// `nonisolated(unsafe)` is deliberate: `AsyncStream.Continuation.yield` is
    /// thread-safe, and all yields from `DownloadManager` are serialized by that
    /// actor. The worker Task is only mutated from ``shutdown()`` on this actor.
    private final class State: @unchecked Sendable {
        let continuation: AsyncStream<PersistOp>.Continuation
        var worker: Task<Void, Never>?

        init(continuation: AsyncStream<PersistOp>.Continuation) {
            self.continuation = continuation
        }
    }

    nonisolated(unsafe) private let state: State
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
