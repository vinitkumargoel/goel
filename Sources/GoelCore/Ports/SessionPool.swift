import Foundation

/// Never deallocate: corelibs `_MultiHandle` teardown `fatalError`s as SIGILL, killing the daemon.
enum SessionPool {
    private static let lock = NSLock()
    private static var sessions: [String: URLSession] = [:]
    private static var retired: [URLSession] = []

    /// `key` must distinguish configurations that may not share a session — the proxy above all.
    static func session(key: String, make: () -> URLSession) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }
        let created = make()
        sessions[key] = created
        return created
    }

    static func retire(_ session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        retired.append(session)
    }

    /// nil (follow the OS) and empty (explicitly direct) are different policies and must not collide.
    static func proxyKey(_ proxy: [String: Any]?) -> String {
        guard let proxy else { return "proxy:system" }
        if proxy.isEmpty { return "proxy:direct" }
        return "proxy:" + proxy.keys.sorted().map { "\($0)=\(proxy[$0].map { "\($0)" } ?? "")" }
            .joined(separator: "&")
    }
}
