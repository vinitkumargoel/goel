#if !os(Linux)
import XCTest
import Network
@testable import GoelCore
#if canImport(Darwin)
import Darwin
#endif

final class RemoteServerHostAndBindTests: XCTestCase {

    private func send(_ request: String, port: UInt16) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .ipv4(.loopback),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = DispatchQueue(label: "host-probe.\(port)")
            var finished = false
            func finish(_ value: String?) {
                done.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            finish(data.map { String(decoding: $0, as: UTF8.self) })
                        }
                    })
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            done.asyncAfter(deadline: .now() + 1.0) { finish(nil) }
            conn.start(queue: done)
        }
    }

    private final class Backend: RemoteBackend, @unchecked Sendable {
        func taskSnapshot() async -> [DownloadTask] { [] }
        func task(_ id: UUID) async -> DownloadTask? { nil }
        func pauseAll() async {}
        func resumeAll() async {}
        func pause(_ id: UUID) async {}
        func resume(_ id: UUID) async {}
        func retry(_ id: UUID) async {}
        func remove(_ id: UUID, deleteData: Bool) async {}
        func forceRecheck(_ id: UUID) async {}
        func setSequential(_ sequential: Bool, task id: UUID) async {}
        func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {}
        func remoteAdd(source: DownloadSource) async {}
        func remoteAdd(source: DownloadSource, saveDirectory: String?,
                       priority: FilePriority, startPaused: Bool) async {}
        func history(limit: Int) async -> [HistoryEntry] { [] }
        func removeHistoryEntry(_ id: UUID) async {}
        func clearHistory() async {}
    }

    /// DNS rebinding: an open (no sign-in) portal reached under a foreign name must answer nothing.
    func testForeignHostIsRefusedOnEveryRoute() async throws {
        let backend = Backend()
        let server = RemoteControlServer(manager: backend)
        let port = LoopbackPort.reserve()
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "", requireAuth: false),
                           passwordHash: "", sessionMinutes: 60,
                           security: RemotePortalSecurity(allowedHosts: []))
        guard await server.boundState() != nil else { throw XCTSkip("could not bind loopback") }
        defer { Task { await server.stop() } }

        var local: String?
        for _ in 0..<30 {
            local = await send("GET /api/config HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n",
                               port: port)
            if local != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let localReply = try XCTUnwrap(local)
        XCTAssertTrue(localReply.hasPrefix("HTTP/1.1 200"), localReply)

        for path in ["/api/config", "/api/events", "/stream?id=x", "/"] {
            let reply = await send(
                "GET \(path) HTTP/1.1\r\nHost: evil.example:\(port)\r\nConnection: close\r\n\r\n", port: port)
            let out = try XCTUnwrap(reply)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 421"), "\(path): \(out)")
        }
    }

    /// FAIL-1: a port someone else holds must surface as a bind failure, not a portal that "runs".
    func testOccupiedPortIsReportedAsABindFailure() async throws {
        let port = LoopbackPort.reserve()
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(blocker, 0)
        defer { close(blocker) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(blocker, 1) == 0 else { throw XCTSkip("could not occupy a port") }

        let server = RemoteControlServer(manager: Backend())
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t", requireAuth: true),
                           passwordHash: "", sessionMinutes: 60)
        defer { Task { await server.stop() } }
        if await server.boundState() != nil {
            throw XCTSkip("this system let a second listener share the port")
        }
        let failure = await server.lastStartFailure()
        XCTAssertEqual(failure, .bindFailed(port: port))
    }
}
#endif
