import Foundation
import XCTest
@testable import GoelCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Loopback port reservation

/// A source of loopback TCP ports that nothing else on the machine is holding.
///
/// WHY THIS EXISTS — a real, reproduced flake.
///
/// The portal tests used to name their ports (18973–18976, 19800…), and
/// ``RemoteControlServer`` binds with `allowLocalEndpointReuse = true`. That flag
/// is correct in production: every settings change stops and restarts the server
/// on the same port, and without endpoint reuse the rebind would fail while the
/// old socket sat in `TIME_WAIT` — the exact silent-death bug
/// ``RemoteServerRestartTests`` was written to guard.
///
/// The side effect is that a *second* process asking for the same port is not
/// refused with `EADDRINUSE`; it is given the port as well, and Darwin then
/// routes new connections to the most recent binder. So when two test processes
/// overlap — two agents on one checkout, or a developer running the suite while
/// something else does — their portals silently share a socket. A probe aimed at
/// "my" server is answered by the other one, or refused outright if that server
/// happens to be between its `stop()` and its `start()`. Running two suites
/// concurrently reproduces this every single time: exactly one of the pair fails
/// `testConfigChangeOnSamePortKeepsServing` with `XCTUnwrap failed`, reported as
/// `1 failure (0 unexpected)`, and it disappears as soon as the runs stop
/// overlapping — which is precisely what makes it look like a ghost.
///
/// The cure is to stop naming ports and let the kernel choose. Binding a
/// throwaway socket to port 0 *without* any reuse option makes the kernel hand
/// back a port it currently considers exclusively free; closing that socket
/// releases the number for the server about to claim it. Two concurrent runs then
/// cannot pick the same port, because the kernel never offers a live one twice.
enum LoopbackPort {

    /// Ports already handed out in this process.
    ///
    /// The kernel only promises a port is free *at the moment it is asked*. A
    /// listener started by an earlier test in this process may still be holding a
    /// port the kernel is willing to recycle, so tests that need to listen at the
    /// same time have to be kept apart here as well as across processes.
    private static let issuedLock = NSLock()
    private static var issued: Set<UInt16> = []

    /// A loopback port that is free right now and has not been issued to this
    /// process before.
    ///
    /// Fails the calling test rather than returning a guess: a fabricated port
    /// would reintroduce the very collision this type exists to remove, and would
    /// do it in the form of a mysterious timeout rather than a clear error.
    static func reserve(file: StaticString = #filePath, line: UInt = #line) -> UInt16 {
        for _ in 0..<64 {
            guard let port = askKernelForAFreePort() else { continue }
            issuedLock.lock()
            let isNew = issued.insert(port).inserted
            issuedLock.unlock()
            if isNew { return port }
        }
        XCTFail("could not reserve a free loopback port", file: file, line: line)
        return 0
    }

    /// Bind `127.0.0.1:0`, read back the port the kernel chose, and release it.
    ///
    /// Deliberately sets no `SO_REUSEADDR` / `SO_REUSEPORT`: the whole point is to
    /// be told a port that nothing else currently holds, which is exactly the
    /// answer those options suppress.
    private static func askKernelForAFreePort() -> UInt16? {
        let descriptor = socket(AF_INET, PlatformSocket.stream, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                   // "any free port"
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let didBind = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didName = withUnsafeMutablePointer(to: &assigned) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard didName == 0 else { return nil }

        let port = UInt16(bigEndian: assigned.sin_port)
        return port == 0 ? nil : port
    }
}

// MARK: - Shared portal credentials

/// Portal password hashes shared across the suite.
///
/// WHY SHARED. ``RemotePassword/hash(_:)`` is PBKDF2-HMAC-SHA256 at 210,000
/// iterations. That cost is the entire point of the function and must never be
/// lowered in production — but in an unoptimised test build one call costs
/// roughly two seconds, and the suite was paying it seven times.
///
/// Most of those calls did not care what was being hashed. They needed "a
/// password is set", "the stored hash is different from the last one", or "these
/// credentials were rotated" — properties that a hash computed once satisfies as
/// well as a hash computed per test. These are `static let`, so each is derived
/// at most once per test process no matter how many tests read it.
///
/// The plaintext is published beside the hash so the tests that genuinely verify
/// — ``RemoteAuthHardeningTests``, which drives a real login through
/// ``RemoteSessionStore/handleLogin(_:client:)`` — still perform a real PBKDF2
/// verification against a real hash. Nothing here weakens the KDF's own coverage:
/// ``SecurityHardeningTests`` deliberately keeps hashing for itself, and remains
/// the place that asserts the `v2` prefix, correct- and wrong-password
/// verification, the empty-password case, and the fresh salt per hash.
enum PortalTestCredentials {

    /// The password a portal under test is configured with.
    static let password = "portal-test-secret"

    /// ``password`` as stored — a real `v2$salt$digest` string, derived once.
    static let hash = RemotePassword.hash(password)

    /// A second, different password, for the "the admin rotated it" cases.
    static let rotatedPassword = "portal-test-rotated"

    /// ``rotatedPassword`` as stored. Distinct from ``hash`` in both salt and
    /// digest, so a test asserting "the credentials changed" is asserting on a
    /// genuine change rather than on a re-salt of the same secret.
    static let rotatedHash = RemotePassword.hash(rotatedPassword)
}
