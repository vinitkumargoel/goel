import XCTest
@testable import GoelCore

/// In-memory ``RemoteBackend`` so the router's routing/auth/API can be exercised
/// with no socket and no live scheduler.
final class FakeRemoteBackend: RemoteBackend, @unchecked Sendable {
    var tasks: [DownloadTask]
    private(set) var pausedAll = false
    private(set) var resumedAll = false
    private(set) var paused: [UUID] = []
    private(set) var resumed: [UUID] = []
    private(set) var added: [DownloadSource] = []

    init(tasks: [DownloadTask] = []) { self.tasks = tasks }

    func taskSnapshot() async -> [DownloadTask] { tasks }
    func task(_ id: UUID) async -> DownloadTask? { tasks.first { $0.id == id } }
    func pauseAll() async { pausedAll = true }
    func resumeAll() async { resumedAll = true }
    func pause(_ id: UUID) async { paused.append(id) }
    func resume(_ id: UUID) async { resumed.append(id) }
    func remoteAdd(source: DownloadSource) async { added.append(source) }
}

final class RemoteRouterTests: XCTestCase {

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    private func request(_ raw: String) -> RemoteRequest {
        RemoteRequest(raw: Data(raw.utf8))
    }

    private func task(_ id: UUID, _ name: String) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e/\(name)")!),
                     name: name, saveDirectory: "/tmp", status: .downloading)
    }

    // MARK: Auth

    func testMissingTokenIs401() async {
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        let out = str(await router.handle(request("GET /api/tasks HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 401 Unauthorized"))
    }

    func testWrongTokenIs401() async {
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        let out = str(await router.handle(request("GET /api/tasks?token=nope HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 401"))
    }

    func testBearerHeaderAuthorizes() async {
        let backend = FakeRemoteBackend(tasks: [task(UUID(), "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request(
            "GET /api/tasks HTTP/1.1\r\nAuthorization: Bearer secret\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(out.contains("application/json"))
    }

    // MARK: Routes

    func testControlPageServedWithCSP() async {
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        let out = str(await router.handle(request("GET /?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(out.contains("text/html"))
        XCTAssertTrue(out.contains("Content-Security-Policy:"))
        XCTAssertTrue(out.contains("<title>Goel"))
    }

    func testTasksJSONCarriesTaskName() async {
        let backend = FakeRemoteBackend(tasks: [task(UUID(), "movie.mkv")])
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request("GET /api/tasks?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.contains("application/json"))
        XCTAssertTrue(out.contains("movie.mkv"))
    }

    func testPauseRouteDispatchesToBackend() async {
        let id = UUID()
        let backend = FakeRemoteBackend(tasks: [task(id, "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request(
            "POST /api/pause?id=\(id.uuidString)&token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.paused, [id])
    }

    func testPauseAllAndResumeAll() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(request("POST /api/pause-all?token=secret HTTP/1.1\r\n\r\n"))
        _ = await router.handle(request("POST /api/resume-all?token=secret HTTP/1.1\r\n\r\n"))
        XCTAssertTrue(backend.pausedAll)
        XCTAssertTrue(backend.resumedAll)
    }

    func testAddRouteParsesJSONBody() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request(
            "POST /api/add?token=secret HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"url\":\"https://e/x.bin\"}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.added.first?.locator, "https://e/x.bin")
    }

    func testUnknownRouteIs404() async {
        let router = RemoteRouter(backend: FakeRemoteBackend(), token: "secret")
        let out = str(await router.handle(request("GET /nope?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 404 Not Found"))
    }

    func testNilBackendIs503() async {
        let router = RemoteRouter(backend: nil, token: "secret")
        let out = str(await router.handle(request("GET /api/tasks?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 503"))
    }
}
