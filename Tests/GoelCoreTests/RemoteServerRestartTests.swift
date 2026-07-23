import XCTest
import Network
@testable import GoelCore
@testable import GoelRemoteServer

/// Integration regression for the embedded server's restart path.
///
/// Every settings change restarts the server: ``AppViewModel/applyRemoteAccess``
/// calls ``RemoteControlServer/stop()`` then ``RemoteControlServer/start(port:allowLAN:config:passwordHash:sessionMinutes:)``
/// on the *same* loopback port. Before `allowLocalEndpointReuse`, that rebind
/// failed with EADDRINUSE — and because an `NWListener` surfaces post-start
/// failures only through its state handler (which the server didn't have), the
/// failure was silent: the UI still showed the portal "enabled" while nothing was
/// listening, so a browser got connection-refused. This exercises the real actor
/// through a restart and proves the port still serves an authenticated request.
final class RemoteServerRestartTests: XCTestCase {

    /// Fire a raw `GET /api/config?token=t` over a fresh loopback TCP connection
    /// and return the first response line (the HTTP status line), or `nil` if the
    /// connection is refused / times out. Uses `NWConnection` directly so the probe
    /// doesn't depend on URLSession/ATS behaviour for cleartext loopback.
    private func probe(port: UInt16) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .ipv4(.loopback),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = DispatchQueue(label: "probe.\(port)")
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
                    let req = "GET /api/config?token=t HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                            let line = data.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "\r\n").first.map(String.init) }
                            finish(line)
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                case .waiting:
                    // Connection refused / not listening yet — NWConnection retries
                    // in .waiting rather than failing outright. Treat it as "not up"
                    // so the caller's poll loop retries instead of hanging here.
                    finish(nil)
                default:
                    break
                }
            }
            // Hard backstop so a stuck connection can never hang the test.
            done.asyncAfter(deadline: .now() + 0.5) { finish(nil) }
            conn.start(queue: done)
        }
    }

    /// Poll `port` until it serves `200`, or fail after ~5s.
    private func expectServes(port: UInt16, _ message: String) async throws {
        var status: String?
        for _ in 0..<50 {
            if let line = await probe(port: port), line.contains("HTTP/1.1") {
                status = line
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let line = try XCTUnwrap(status, message)
        XCTAssertTrue(line.contains("200"), "\(message) — got: \(line)")
    }

    /// The user's exact scenario: enable the portal, then change a *non-bind*
    /// setting (a password). The port must keep serving — this is where a rebind
    /// used to silently kill the socket.
    func testConfigChangeOnSamePortKeepsServing() async throws {
        let manager = DownloadManager()               // held strongly: server keeps it weak
        let server = RemoteControlServer(manager: manager)
        let port: UInt16 = 18973

        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t"),
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: port, "portal should serve right after enabling")

        // Set a password (credentials change) — same port, so no rebind.
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t", requireAuth: true, username: "admin"),
                           passwordHash: RemotePassword.hash("hunter2"), sessionMinutes: 120)
        try await expectServes(port: port, "portal must keep serving after a settings change")

        await server.stop()
    }

    /// A genuine bind change (new port) must tear down the old socket and rebind
    /// cleanly — exercising the awaited teardown in stop().
    func testPortChangeRebindsCleanly() async throws {
        let manager = DownloadManager()               // held strongly: server keeps it weak
        let server = RemoteControlServer(manager: manager)
        let config = RemoteRouter.Config(token: "t")

        await server.start(port: 18974, allowLAN: false, config: config,
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: 18974, "portal should serve on the first port")

        await server.start(port: 18975, allowLAN: false, config: config,
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: 18975, "portal must serve on the new port after a rebind")

        await server.stop()
    }

    /// Regression for the POST-body accumulator: a request whose body arrives in a
    /// *separate* TCP segment from its headers must still be read in full. Before
    /// the fix the macOS server did one un-re-armed `receive`, so it parsed a
    /// truncated (empty) body and `/api/add` failed with 400. The header block is
    /// sent first, then — after a delay — the JSON body, forcing the server to
    /// re-arm its receive to see the body at all.
    func testSplitPostBodyIsReadInFull() async throws {
        let manager = DownloadManager()
        let server = RemoteControlServer(manager: manager)
        let port: UInt16 = 18976

        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t"),
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: port, "portal should serve before the split-POST probe")

        let status = await splitPostAddStatus(port: port)
        await server.stop()

        let line = try XCTUnwrap(status, "split POST got no response")
        XCTAssertTrue(line.contains("200"),
                      "a POST body split across TCP segments must be read in full — got: \(line)")
    }

    /// Open a loopback connection, send `POST /api/add`'s headers, pause, then send
    /// the body in a second write. Returns the response status line, or nil.
    private func splitPostAddStatus(port: UInt16) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .ipv4(.loopback),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = DispatchQueue(label: "splitpost.\(port)")
            var finished = false
            func finish(_ value: String?) {
                done.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            let body = Data(#"{"url":"magnet:?xt=urn:btih:0000000000000000000000000000000000000000"}"#.utf8)
            let head = "POST /api/add?token=t HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                + "Connection: close\r\n\r\n"
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                        done.asyncAfter(deadline: .now() + 0.1) {
                            conn.send(content: body, completion: .contentProcessed { _ in
                                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                                    let line = data.flatMap {
                                        String(decoding: $0, as: UTF8.self).split(separator: "\r\n").first.map(String.init)
                                    }
                                    finish(line)
                                }
                            })
                        }
                    })
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            done.asyncAfter(deadline: .now() + 2.0) { finish(nil) }
            conn.start(queue: done)
        }
    }
}
