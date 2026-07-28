#if !os(Linux)
import XCTest
import Network
@testable import GoelCore

final class RemoteServerRestartTests: XCTestCase {

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
                    // A refused connection stays in `.waiting` forever; without this the poll loop hangs.
                    finish(nil)
                default:
                    break
                }
            }
            done.asyncAfter(deadline: .now() + 0.5) { finish(nil) }
            conn.start(queue: done)
        }
    }

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

    func testConfigChangeOnSamePortKeepsServing() async throws {
        let manager = DownloadManager()               // held strongly: server keeps it weak
        let server = RemoteControlServer(manager: manager)
        let port = LoopbackPort.reserve()

        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t"),
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: port, "portal should serve right after enabling")

        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "t", requireAuth: true, username: "admin"),
                           passwordHash: PortalTestCredentials.hash, sessionMinutes: 120)
        try await expectServes(port: port, "portal must keep serving after a settings change")

        await server.stop()
    }

    func testPortChangeRebindsCleanly() async throws {
        let manager = DownloadManager()               // held strongly: server keeps it weak
        let server = RemoteControlServer(manager: manager)
        let config = RemoteRouter.Config(token: "t")
        // Two independently reserved ports: reusing/incrementing one makes "rebound" indistinguishable from "never moved".
        let firstPort = LoopbackPort.reserve()
        let secondPort = LoopbackPort.reserve()

        await server.start(port: firstPort, allowLAN: false, config: config,
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: firstPort, "portal should serve on the first port")

        await server.start(port: secondPort, allowLAN: false, config: config,
                           passwordHash: "", sessionMinutes: 120)
        try await expectServes(port: secondPort, "portal must serve on the new port after a rebind")

        await server.stop()
    }

    func testSplitPostBodyIsReadInFull() async throws {
        let manager = DownloadManager()
        let server = RemoteControlServer(manager: manager)
        let port = LoopbackPort.reserve()

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

#endif
