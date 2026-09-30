import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import GoelCore

#if canImport(Darwin)
private let streamType = SOCK_STREAM
private func systemBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    Darwin.bind(fd, addr, len)
}
#else
private let streamType = Int32(SOCK_STREAM.rawValue)
private func systemBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    Glibc.bind(fd, addr, len)
}
#endif

/// A pause that lands while FTP/SFTP is still probing the size used to be lost: the transfer ran on, and the
/// next resume waited for the whole file. The probe here stalls against a server that never speaks.
final class RemoteProbePauseTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-probe-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Accepts TCP connections into the backlog and never answers; closing it resets them.
    private final class SilentServer {
        let fd: Int32
        let port: Int

        init() throws {
            let sock = socket(AF_INET, streamType, 0)
            guard sock >= 0 else { throw XCTSkip("no socket") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(sock, 8) == 0 else { close(sock); throw XCTSkip("can't listen") }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
            }
            fd = sock
            port = Int(UInt16(bigEndian: addr.sin_port))
        }

        func stop() { close(fd) }
    }

    private func run(engine: any DownloadEngine, url: URL) async throws {
        let task = DownloadTask(source: .url(url), name: "file.bin", saveDirectory: dir.path)
        let failed = Task { () -> Bool in
            for await event in engine.events(for: task.id) { if case .failed = event { return true } }
            return false
        }
        await engine.add(task)
        try await Task.sleep(nanoseconds: 400_000_000)   // inside the probe
        await engine.pause(task.id)
        server.stop()                                    // the probe now fails fast
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: task.savePath),
                       "a paused task must not go on to open its file and transfer")
        await engine.remove(task.id, deleteData: false)
        let sawFailure = await failed.value
        XCTAssertFalse(sawFailure, "the pause is the outcome, not a network failure")
    }

    private var server: SilentServer!

    func testFTPPauseDuringSizeProbeStopsTheJob() async throws {
        server = try SilentServer()
        let engine = FTPEngine(profile: .high, credentialLookup: { _ in nil })
        try await run(engine: engine, url: URL(string: "ftp://127.0.0.1:\(server.port)/file.bin")!)
    }

    func testSFTPPauseDuringSizeProbeStopsTheJob() async throws {
        server = try SilentServer()
        let engine = SFTPEngine(profile: .high)
        try await run(engine: engine, url: URL(string: "sftp://u:p@127.0.0.1:\(server.port)/file.bin")!)
    }
}
