import Foundation

/// Decides whether to pin a host key the app has never seen before.
///
/// The credential is offered *after* the host-key check (see `gsb_open` in the
/// SSH bridge), so learning a key from a connection that already authenticated
/// protects every connection except the one an attacker would actually target.
/// An approver is consulted before that first authenticated connection is made
/// at all, from a key-only pre-flight that offers no credential.
public protocol HostKeyApproving: Sendable {
    /// Decide whether to pin `fingerprint` for a host with no existing pin.
    func approveFirstContact(host: String, port: Int, fingerprint: String) async -> Bool
}

/// Where the first-contact policy is installed.
///
/// Nil is classic trust-on-first-use, which is the only workable policy where
/// there is nobody to ask — the Linux daemon, the `sftp://` URL paths and the
/// tests. GoelApp installs an approver at launch so the GUI never pins a key the
/// user didn't see. The closed policy is therefore opt-in: a fail-closed default
/// would break every headless path outright.
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
