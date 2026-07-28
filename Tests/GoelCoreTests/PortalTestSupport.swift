import Foundation
import XCTest
@testable import GoelCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Hard-coded ports flake: `allowLocalEndpointReuse = true` lets a second test process share the socket.
enum LoopbackPort {

    /// The kernel only promises a port is free at the moment asked; an earlier listener may still hold it.
    private static let issuedLock = NSLock()
    private static var issued: Set<UInt16> = []

    /// Fails the test rather than guessing: a fabricated port returns as a mysterious timeout instead.
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

    /// Never add `SO_REUSEADDR`/`SO_REUSEPORT`: they suppress the "nothing else holds this" answer needed.
    private static func askKernelForAFreePort() -> UInt16? {
        let descriptor = socket(AF_INET, PlatformSocket.stream, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
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

/// Keep these `static let`: ``RemotePassword/hash(_:)`` is PBKDF2 at 210,000 iterations (~2 s per call).
enum PortalTestCredentials {

    static let password = "portal-test-secret"

    static let hash = RemotePassword.hash(password)

    static let rotatedPassword = "portal-test-rotated"

    static let rotatedHash = RemotePassword.hash(rotatedPassword)
}
