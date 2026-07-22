import XCTest
@testable import GoelCore

/// In-memory ``RemoteBackend`` so the router's routing/auth/API can be exercised
/// with no socket and no live scheduler.
final class FakeRemoteBackend: RemoteBackend, @unchecked Sendable {
    var tasks: [DownloadTask]
    var historyEntries: [HistoryEntry] = []
    private(set) var pausedAll = false
    private(set) var resumedAll = false
    private(set) var paused: [UUID] = []
    private(set) var resumed: [UUID] = []
    private(set) var retried: [UUID] = []
    private(set) var removed: [(UUID, Bool)] = []
    private(set) var rechecked: [UUID] = []
    private(set) var sequenced: [(UUID, Bool)] = []
    private(set) var filePriorities: [(UUID, Int, FilePriority)] = []
    private(set) var added: [DownloadSource] = []
    private(set) var clearedHistory = false

    init(tasks: [DownloadTask] = []) { self.tasks = tasks }

    func taskSnapshot() async -> [DownloadTask] { tasks }
    func task(_ id: UUID) async -> DownloadTask? { tasks.first { $0.id == id } }
    func pauseAll() async { pausedAll = true }
    func resumeAll() async { resumedAll = true }
    func pause(_ id: UUID) async { paused.append(id) }
    func resume(_ id: UUID) async { resumed.append(id) }
    func retry(_ id: UUID) async { retried.append(id) }
    func remove(_ id: UUID, deleteData: Bool) async { removed.append((id, deleteData)) }
    func forceRecheck(_ id: UUID) async { rechecked.append(id) }
    func setSequential(_ sequential: Bool, task id: UUID) async { sequenced.append((id, sequential)) }
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        filePriorities.append((id, fileID, priority))
    }
    func remoteAdd(source: DownloadSource) async { added.append(source) }
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async { added.append(source) }
    func history(limit: Int) async -> [HistoryEntry] { historyEntries }
    func removeHistoryEntry(_ id: UUID) async { historyEntries.removeAll { $0.id == id } }
    func clearHistory() async { clearedHistory = true }
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

    /// The highest-severity finding in the design review. A local `folder` is merely constrained to the downloads root; a *server* destination has no equivalent containment, because it would have to hold on someone else's filesystem. An authenticated portal client choosing it would be picking an arbitrary write path on the SFTP host — `~/.ssh/authorized_keys`, `/etc/cron.d` — turning a download manager into remote code execution on a third machine.
    ///
    /// A refusal, not a warning, and refused regardless of whether the feature is switched on: portal clients are headless and cannot answer a host-key prompt anyway.
    func testAddRouteRefusesAClientSuppliedServerDestination() async {
        for field in ["server", "serverID", "remoteDestination"] {
            let backend = FakeRemoteBackend()
            let router = RemoteRouter(backend: backend, token: "secret")
            let body = "{\"url\":\"https://e/x.bin\",\"\(field)\":\"media-box\"}"
            let out = str(await router.handle(request(
                "POST /api/add?token=secret HTTP/1.1\r\nContent-Type: application/json\r\n\r\n\(body)")))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(field) should be refused, got: \(out.prefix(40))")
            XCTAssertTrue(backend.added.isEmpty, "\(field): nothing should be queued")
        }
    }

    /// The refusal must not become a denial of service for ordinary adds that merely carry an empty field.
    func testAddRouteStillAcceptsAnEmptyServerField() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request(
            "POST /api/add?token=secret HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"url\":\"https://e/x.bin\",\"server\":\"\"}")))
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

    // MARK: New routes

    func testRemoveRouteCarriesDeleteFlag() async {
        let id = UUID()
        let backend = FakeRemoteBackend(tasks: [task(id, "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(request("POST /api/remove?id=\(id.uuidString)&data=1&token=secret HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(backend.removed.first?.0, id)
        XCTAssertEqual(backend.removed.first?.1, true)
    }

    func testFilePriorityRouteParsesArgs() async {
        let id = UUID()
        let backend = FakeRemoteBackend(tasks: [task(id, "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(request(
            "POST /api/file-priority?id=\(id.uuidString)&file=3&prio=skip&token=secret HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(backend.filePriorities.first?.1, 3)
        XCTAssertEqual(backend.filePriorities.first?.2, .skip)
    }

    func testRetryRouteDispatches() async {
        let id = UUID()
        let backend = FakeRemoteBackend(tasks: [task(id, "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(request("POST /api/retry?id=\(id.uuidString)&token=secret HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(backend.retried, [id])
    }

    func testReadOnlyModeBlocksMutations() async {
        let backend = FakeRemoteBackend()
        let config = RemoteRouter.Config(token: "secret", readOnly: true)
        let router = RemoteRouter(backend: backend, config: config)
        let out = str(await router.handle(request("POST /api/pause-all?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"))
        XCTAssertFalse(backend.pausedAll)
    }

    func testReadOnlyModeAllowsReads() async {
        let backend = FakeRemoteBackend(tasks: [task(UUID(), "a")])
        let config = RemoteRouter.Config(token: "secret", readOnly: true)
        let router = RemoteRouter(backend: backend, config: config)
        let out = str(await router.handle(request("GET /api/tasks?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
    }

    func testConfigRouteReportsThemeAndUser() async {
        let config = RemoteRouter.Config(token: "secret", theme: "nord", username: "vinit")
        let router = RemoteRouter(backend: FakeRemoteBackend(), config: config)
        let out = str(await router.handle(request("GET /api/config?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.contains("nord"))
        XCTAssertTrue(out.contains("vinit"))
    }

    func testOpenAccessNeedsNoToken() async {
        let config = RemoteRouter.Config(token: "", requireAuth: false)
        let router = RemoteRouter(backend: FakeRemoteBackend(), config: config)
        let out = str(await router.handle(request("GET /api/tasks HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
    }

    func testSessionAuthorizesWithoutToken() async {
        let backend = FakeRemoteBackend(tasks: [task(UUID(), "a")])
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request("GET /api/tasks HTTP/1.1\r\n\r\n"), sessionAuthed: true))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
    }
}
