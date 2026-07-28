import Foundation
import SSHBridge

/// libssh2 sessions are not thread-safe, so one connection is pinned to one thread; `@unchecked Sendable` because state is guarded by `condition`.
final class SFTPSessionChannel: @unchecked Sendable {

    private typealias Job = @Sendable (OpaquePointer?, GSBResult) -> Void

    private let target: SFTPTarget
    /// The fingerprint this channel must match, or nil for trust-on-first-use.
    private let expected: String?
    /// Long enough to cover reading a listing and clicking again, short enough not to sit on a server's session slot.
    private let idleTimeout: TimeInterval

    private let condition = NSCondition()
    private var pending: [Job] = []
    private var isStopped = false
    private var threadStarted = false

    /// Only touched on the owning thread.
    private var session: OpaquePointer?

    /// Set from any thread, consumed on the owning thread.
    private var shouldDropSession = false

    /// Guarded by `condition`: the caller reads it from another thread.
    private var learnedFingerprint: String?

    init(target: SFTPTarget, expected: String?, idleTimeout: TimeInterval = 90) {
        self.target = target
        self.expected = expected
        self.idleTimeout = idleTimeout
    }

    // No `deinit` cleanup: the running loop holds a strong reference, so `deinit` cannot fire while a connection is open — the owner must call `shutdown()`.

    var fingerprint: String? {
        condition.lock(); defer { condition.unlock() }
        return learnedFingerprint
    }

    /// Credentials and pin are captured at init and reused on every reconnect, so a stale channel would re-auth with a since-changed password or key.
    func matches(target other: SFTPTarget, expected otherExpected: String?) -> Bool {
        target == other && expected == otherExpected
    }

    func perform(_ body: @escaping @Sendable (OpaquePointer) -> GSBResult) async -> GSBResult {
        await withCheckedContinuation { (cont: CheckedContinuation<GSBResult, Never>) in
            submit { handle, openFailure in
                guard let handle else { cont.resume(returning: openFailure); return }
                cont.resume(returning: body(handle))
            }
        }
    }

    func disconnect() {
        condition.lock()
        shouldDropSession = true
        condition.broadcast()
        condition.unlock()
    }

    func shutdown() {
        condition.lock()
        isStopped = true
        condition.broadcast()
        condition.unlock()
    }

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
        // libssh2's own frames plus our callbacks need the headroom.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Everything that touches `session` happens on this thread.
    private func runLoop() {
        while true {
            condition.lock()
            while pending.isEmpty && !isStopped && !shouldDropSession {
                if session != nil {
                    if !condition.wait(until: Date().addingTimeInterval(idleTimeout)) {
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
                // Every queued job owns a continuation: dropping one instead of answering it hangs the awaiting task forever.
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

            // The thread outlives every job, so without this pool everything autoreleased accumulates until the channel shuts down.
            autoreleasepool {
                let (handle, failure) = ensureConnected()
                job(handle, failure)
            }
        }
    }

    private func ensureConnected() -> (OpaquePointer?, GSBResult) {
        var result = GSBResult()

        if let existing = session {
            if gsb_session_alive(existing) != 0 { return (existing, result) }
            // Reconnecting is safe only because this runs between jobs, never mid-operation, so no half-applied mutation is replayed.
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

    private static func closedResult() -> GSBResult {
        var failed = GSBResult()
        failed.code = Int32(GSB_ERR_SFTP)
        setMessage(&failed, "This connection has been closed.")
        return failed
    }

    private static func setMessage(_ result: inout GSBResult, _ text: String) {
        withUnsafeMutableBytes(of: &result.message) { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = Array(text.utf8.prefix(raw.count - 1))
            base.copyMemory(from: bytes, byteCount: bytes.count)
            base.advanced(by: bytes.count).assumingMemoryBound(to: CChar.self).pointee = 0
        }
    }

    /// The nested `withCString` calls keep every C string alive for the whole of `body` — do not flatten them.
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
