import Foundation
import SSHBridge

/// One authenticated SFTP connection, pinned for life to a dedicated thread.
///
/// libssh2 sessions are not thread-safe, so a `GSBSession *` may only ever be
/// touched from the thread that opened it. This type is the enforcement: it owns
/// a thread, that thread owns the session, and every operation is a closure
/// posted to a serial queue the thread drains. Callers never see the pointer
/// outside the closure.
///
/// The connection is opened lazily on the first operation and then *kept*, which
/// is the whole point — the handshake (TCP connect, key exchange, host-key
/// verification, authentication, SFTP channel init) costs several round trips
/// plus asymmetric crypto, and paying it per operation is what made every folder
/// click and every file of a folder upload wear a full handshake.
///
/// `@unchecked Sendable`: the mutable state below is guarded by `condition`, and
/// the session pointer is only ever dereferenced on `thread`.
final class SFTPSessionChannel: @unchecked Sendable {

    /// A unit of work to run against the live session on the owning thread.
    private typealias Job = @Sendable (OpaquePointer?, GSBResult) -> Void

    private let target: SFTPTarget
    /// The fingerprint this channel must match, or nil for trust-on-first-use.
    private let expected: String?
    /// How long an idle connection is held open before being dropped. Long
    /// enough to cover a person reading a directory listing and clicking again;
    /// short enough not to sit on a server's session slot indefinitely.
    private let idleTimeout: TimeInterval

    private let condition = NSCondition()
    private var pending: [Job] = []
    private var isStopped = false
    private var threadStarted = false

    /// Only touched on the owning thread.
    private var session: OpaquePointer?

    /// Set from any thread, consumed on the owning thread: drop the connection
    /// but keep the channel usable.
    private var shouldDropSession = false

    /// The host key the live session connected with, published for pinning.
    /// Guarded by `condition` because the caller reads it from another thread.
    private var learnedFingerprint: String?

    init(target: SFTPTarget, expected: String?, idleTimeout: TimeInterval = 90) {
        self.target = target
        self.expected = expected
        self.idleTimeout = idleTimeout
    }

    // No `deinit` cleanup: once started, the run loop holds a strong reference to
    // this object for as long as it runs, so `deinit` cannot fire while a
    // connection is open. Lifetime is explicit — the owner calls `shutdown()`.

    /// The fingerprint observed on the most recent successful connect, if any.
    var fingerprint: String? {
        condition.lock(); defer { condition.unlock() }
        return learnedFingerprint
    }

    /// Whether this channel was built for exactly these credentials and this pin.
    ///
    /// Both are captured at init and used for every reconnect, so a channel that
    /// no longer matches must be discarded rather than reused: it would otherwise
    /// keep re-authenticating with a password the user has since changed, or keep
    /// demanding a host key they have since re-approved.
    func matches(target other: SFTPTarget, expected otherExpected: String?) -> Bool {
        target == other && expected == otherExpected
    }

    /// Run one operation against the live session, opening or reopening it first
    /// if needed. Returns the operation's result, or the failure that prevented
    /// the connection being established.
    func perform(_ body: @escaping @Sendable (OpaquePointer) -> GSBResult) async -> GSBResult {
        await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            submit { handle, openFailure in
                guard let handle else { cont.resume(returning: openFailure); return }
                cont.resume(returning: body(handle))
            }
        }
    }

    /// Close the connection now, without tearing down the channel. The next
    /// operation transparently reconnects. Takes effect between jobs, so it never
    /// interrupts an operation already in flight.
    func disconnect() {
        condition.lock()
        shouldDropSession = true
        condition.broadcast()
        condition.unlock()
    }

    /// Permanently stop this channel and close its connection. Jobs submitted
    /// afterwards fail immediately rather than hanging.
    func shutdown() {
        condition.lock()
        isStopped = true
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Plumbing

    private func submit(_ job: @escaping Job) {
        condition.lock()
        if isStopped {
            condition.unlock()
            job(nil, Self.closedResult())
            return
        }
        pending.append(job)
        if !threadStarted {
            threadStarted = true
            startThread()
        }
        condition.signal()
        condition.unlock()
    }

    private func startThread() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "goel.sftp-session"
        // The transfer buffers moved to the heap in the C shim, but libssh2's own
        // frames plus our callbacks still want headroom.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The owning thread's whole life: wait for work, ensure a live connection,
    /// run the job. Everything that touches `session` happens here.
    private func runLoop() {
        while true {
            condition.lock()
            while pending.isEmpty && !isStopped && !shouldDropSession {
                // Wake up on the idle deadline so a connection nobody is using is
                // released rather than held against the server's session limit.
                if session != nil {
                    if !condition.wait(until: Date().addingTimeInterval(idleTimeout)) {
                        // Timed out with no work: drop the idle connection but keep
                        // the thread, so the next click doesn't pay thread startup.
                        let idle = session
                        session = nil
                        condition.unlock()
                        if let idle { gsb_session_close(idle) }
                        condition.lock()
                    }
                } else {
                    condition.wait()
                }
            }
            if isStopped {
                // Anything still queued must be answered, not abandoned — every
                // pending job owns a continuation, and dropping it on the floor
                // would hang the awaiting task forever.
                let orphaned = pending
                pending.removeAll()
                let dying = session
                session = nil
                condition.unlock()
                if let dying { gsb_session_close(dying) }
                let closed = Self.closedResult()
                for job in orphaned { job(nil, closed) }
                return
            }
            if shouldDropSession {
                shouldDropSession = false
                let dying = session
                session = nil
                condition.unlock()
                if let dying { gsb_session_close(dying) }
                continue
            }
            let job = pending.removeFirst()
            condition.unlock()

            let (handle, failure) = ensureConnected()
            job(handle, failure)
        }
    }

    /// Return a live session, opening it if absent and reopening it if the peer
    /// has gone away. On failure returns the `GSBResult` explaining why.
    private func ensureConnected() -> (OpaquePointer?, GSBResult) {
        var result = GSBResult()

        if let existing = session {
            if gsb_session_alive(existing) != 0 { return (existing, result) }
            // The peer closed while we were idle. Drop it and reconnect, which is
            // safe here because this only ever runs between jobs — never in the
            // middle of one, so no half-applied mutation can be replayed.
            gsb_session_close(existing)
            session = nil
        }

        let opened = Self.withAuth(target, expected: expected) { auth in
            gsb_session_open(auth, &result)
        }
        guard let opened else {
            if result.code == GSB_OK {   // defensive: never report a nil session as success
                result.code = Int32(GSB_ERR_SFTP)
                Self.setMessage(&result, "Could not open a connection to this server.")
            }
            return (nil, result)
        }
        session = opened

        let fp = String(cString: gsb_session_fingerprint(opened))
        if !fp.isEmpty {
            condition.lock()
            learnedFingerprint = fp
            condition.unlock()
        }
        return (opened, result)
    }

    /// The failure handed to any job that arrives at, or was queued behind, a
    /// shutdown.
    private static func closedResult() -> GSBResult {
        var failed = GSBResult()
        failed.code = Int32(GSB_ERR_SFTP)
        setMessage(&failed, "This connection has been closed.")
        return failed
    }

    /// Write a message into a `GSBResult`'s fixed-size C buffer.
    private static func setMessage(_ result: inout GSBResult, _ text: String) {
        withUnsafeMutableBytes(of: &result.message) { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = Array(text.utf8.prefix(raw.count - 1))
            base.copyMemory(from: bytes, byteCount: bytes.count)
            base.advanced(by: bytes.count).assumingMemoryBound(to: CChar.self).pointee = 0
        }
    }

    /// Marshal a target + optional pinned fingerprint into a `GSBAuth` with
    /// correct C-string lifetimes, and invoke `body`.
    static func withAuth<T>(_ t: SFTPTarget, expected: String?,
                            _ body: (UnsafePointer<GSBAuth>) -> T) -> T {
        func withOpt(_ s: String?, _ f: (UnsafePointer<CChar>?) -> T) -> T {
            if let s { return s.withCString(f) }
            return f(nil)
        }
        return t.host.withCString { host in
            t.username.withCString { user in
                withOpt(t.password) { pass in
                    withOpt(expected) { fp in
                        withOpt(t.privateKeyPath) { keyPath in
                            withOpt(t.keyPassphrase) { keyPhrase in
                                var auth = GSBAuth(host: host, port: Int32(t.port), username: user,
                                                   password: pass, use_agent: t.useAgent ? 1 : 0,
                                                   expected_fp: fp,
                                                   private_key_path: keyPath,
                                                   public_key_path: nil,
                                                   key_passphrase: keyPhrase)
                                return withUnsafePointer(to: &auth) { body($0) }
                            }
                        }
                    }
                }
            }
        }
    }
}
