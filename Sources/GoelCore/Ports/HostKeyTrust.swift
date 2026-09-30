import Foundation

/// Runs from a key-only pre-flight: no credential may be offered until this returns.
public protocol HostKeyApproving: Sendable {
    func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool
}

/// Who confirms an SFTP/SSH host key the first time Goel° meets it. The app installs an approver that asks
/// the user. Nil (the daemon, the CLI, anything headless) is fail-closed, never trust-on-first-use: an
/// unpinned host is refused unless the operator pinned its key in `GOEL_SSH_FINGERPRINTS`
/// (`host[:port]=SHA256:<base64>`, see `ProvisionedHostKeys`), and the refusal quotes the presented key.
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
