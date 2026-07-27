import Foundation

/// Long-lived `URLSession`s, so none is ever deallocated.
///
/// This is not a performance cache. swift-corelibs-foundation's `URLSession` owns
/// a `_MultiHandle` whose teardown is unsound: releasing the last reference to a
/// session can abort the process with *"Object … of class _MultiHandle deallocated
/// with non-zero retain count"* — a Swift runtime `fatalError`, which arrives as
/// `SIGILL` and takes the whole daemon down. It reproduced reliably under the
/// hardened systemd unit while the same code survived in the foreground, which is
/// the worst shape a bug can have: invisible in testing, fatal in production.
///
/// Sessions vended here are kept for the lifetime of the process, so that teardown
/// never runs. They are idle between uses and cost a file descriptor at most.
/// Apple's URLSession does not have the bug, but shares the code path — one
/// behaviour is easier to reason about than two.
enum SessionPool {
    private static let lock = NSLock()
    private static var sessions: [String: URLSession] = [:]
    /// Sessions that were replaced by a reconfiguration. Held, not released.
    private static var retired: [URLSession] = []

    /// - Parameter key: distinguishes configurations that must not share a session
    ///   — the proxy, above all. Callers with identical keys get identical sessions.
    static func session(key: String, make: () -> URLSession) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }
        let created = make()
        sessions[key] = created
        return created
    }

    /// Park a session that is being replaced. Its in-flight tasks are allowed to
    /// finish; the object itself is never freed.
    static func retire(_ session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        retired.append(session)
    }

    /// A stable key for a proxy dictionary, which is `[AnyHashable: Any]` and so
    /// not `Hashable` itself. nil (follow the OS) and empty (explicitly direct) are
    /// different policies and must not collide.
    static func proxyKey(_ proxy: [String: Any]?) -> String {
        guard let proxy else { return "proxy:system" }
        if proxy.isEmpty { return "proxy:direct" }
        return "proxy:" + proxy.keys.sorted().map { "\($0)=\(proxy[$0].map { "\($0)" } ?? "")" }
            .joined(separator: "&")
    }
}
