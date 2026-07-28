import Foundation
import XCTest
@testable import GoelCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Loopback port reservation

/// Loopback TCP ports nothing else holds. Hard-coded ports flaked: `allowLocalEndpointReuse = true` lets a
/// second test process share the socket, so bind port 0 with no reuse option and let the kernel choose.
enum LoopbackPort {

    /// Ports already handed out in this process: the kernel only promises free *at the moment asked*, and
    /// an earlier test's listener may still hold a port the kernel would happily recycle.
    private static let issuedLock = NSLock()
    private static var issued: Set<UInt16> = []

    /// A loopback port free right now and not previously issued in this process. Fails the calling test
    /// rather than guessing — a fabricated port reintroduces the collision as a mysterious timeout.
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

    /// Bind `127.0.0.1:0`, read back the kernel's port, release it. Deliberately no `SO_REUSEADDR` /
    /// `SO_REUSEPORT`: those options suppress exactly the "nothing else holds this" answer we need.
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

/// Portal password hashes shared across the suite: ``RemotePassword/hash(_:)`` is PBKDF2 at 210,000
/// iterations (~2 s per call in a test build), so these `static let`s derive once per test process.
enum PortalTestCredentials {

    /// The password a portal under test is configured with.
    static let password = "portal-test-secret"

    /// ``password`` as stored — a real `v2$salt$digest` string, derived once.
    static let hash = RemotePassword.hash(password)

    /// A second, different password, for the "the admin rotated it" cases.
    static let rotatedPassword = "portal-test-rotated"

    /// ``rotatedPassword`` as stored. Distinct from ``hash`` in both salt and digest, so "the credentials
    /// changed" assertions test a genuine change, not a re-salt of the same secret.
    static let rotatedHash = RemotePassword.hash(rotatedPassword)
}
