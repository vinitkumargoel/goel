import Foundation

/// Long-lived `URLSession`s, never deallocated: corelibs-foundation's `_MultiHandle` teardown is
/// unsound — releasing the last ref `fatalError`s as SIGILL, killing the daemon. Held for process life.
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

    /// A stable key for a proxy dictionary (`[AnyHashable: Any]`, so not `Hashable`). nil (follow
    /// the OS) and empty (explicitly direct) are different policies and must not collide.
    static func proxyKey(_ proxy: [String: Any]?) -> String {
        guard let proxy else { return "proxy:system" }
        if proxy.isEmpty { return "proxy:direct" }
        return "proxy:" + proxy.keys.sorted().map { "\($0)=\(proxy[$0].map { "\($0)" } ?? "")" }
            .joined(separator: "&")
    }
}
