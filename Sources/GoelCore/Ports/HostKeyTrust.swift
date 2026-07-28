import Foundation

/// Decides whether to pin an unseen host key. The credential is offered *after* the host-key check
/// (`gsb_open`), so the approver runs first, from a key-only pre-flight that offers no credential.
public protocol HostKeyApproving: Sendable {
    /// Decide whether to pin `fingerprint` for a host with no existing pin.
    func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool
}

/// Where the first-contact policy is installed. Nil = trust-on-first-use, the only workable policy with
/// nobody to ask (daemon, `sftp://`, tests). GoelApp opts in at launch; a fail-closed default breaks those.
public final class HostKeyTrust: @unchecked Sendable {

    public static let shared = HostKeyTrust()

    private let lock = NSLock()
    private var installed: (any HostKeyApproving)?

    public init() {}

    /// Read from arbitrary transfer threads and written once at launch, hence
    /// the lock rather than a plain stored property.
    public var approver: (any HostKeyApproving)? {
        get { lock.lock(); defer { lock.unlock() }; return installed }
        set { lock.lock(); installed = newValue; lock.unlock() }
    }
}
