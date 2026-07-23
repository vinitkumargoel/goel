import Foundation

/// The actor→sync bridge: run an `async` operation from a *synchronous, blocking*
/// call site and return its result.
///
/// This is the primitive that lets a non-Swift caller (a JNI/JVM thread, a C-ABI
/// shim) drive the engine's actors — `async`/`await` does not cross the JNI
/// boundary, but a blocking call that internally awaits does.
///
/// The work runs on a *detached* task (Swift's global concurrency pool), never on
/// the caller's thread, so parking the caller on the semaphore cannot deadlock the
/// executor that has to finish the work. This is safe **precisely because the
/// caller is expected to be a foreign thread** (the JVM / an app main thread), not
/// one of Swift's cooperative-pool workers: calling this from inside a Swift
/// `Task` would occupy a pool thread while blocked and risk starving the runtime.
/// (`GoelFacade.observe` therefore delivers its callbacks on a private serial
/// queue rather than inline on the pool.)
///
/// Two standing limitations, both inherent to a blocking bridge:
/// - **No timeout / no interruption.** If `operation` never completes, the calling
///   foreign thread parks forever; there is no cancellation handle for a one-shot
///   call. Only ``GoelFacade/observe(_:)`` subscriptions are cancellable.
/// - **Non-throwing only.** Every `DownloadManager` API reached through the facade
///   today is non-throwing. If a `throws` API is ever wired up (e.g.
///   `importEnvelope(_:)`), it must NOT be funnelled through this function — that
///   would silently swallow its error. Add a throwing counterpart that propagates
///   via `Result` instead.
func runBlocking<T: Sendable>(_ operation: @Sendable @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = OneShotBox<T>()
    Task.detached {
        let value = await operation()
        box.set(value)
        semaphore.signal()
    }
    semaphore.wait()
    return box.take()
}

/// A one-shot hand-off cell. The semaphore in ``runBlocking(_:)`` establishes the
/// happens-before edge between the detached task's `set` and the caller's `take`,
/// so the internal lock only guards against a torn read on exotic memory models;
/// `@unchecked Sendable` is sound on that basis.
private final class OneShotBox<T>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()

    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func take() -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else { preconditionFailure("OneShotBox read before it was set") }
        return value
    }
}
