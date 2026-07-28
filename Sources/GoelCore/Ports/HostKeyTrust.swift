import Foundation

/// Runs from a key-only pre-flight: no credential may be offered until this returns.
public protocol HostKeyApproving: Sendable {
    func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool
}

/// Nil = trust-on-first-use: the daemon, `sftp://` and tests have nobody to ask, so a fail-closed default breaks them.
public final class HostKeyTrust: @unchecked Sendable {

    public static let shared = HostKeyTrust()

    private let lock = NSLock()
    private var installed: (any HostKeyApproving)?

    public init() {}

    /// Read from arbitrary transfer threads: the lock is not optional.
    public var approver: (any HostKeyApproving)? {
        get { lock.lock(); defer { lock.unlock() }; return installed }
        set { lock.lock(); installed = newValue; lock.unlock() }
    }
}
