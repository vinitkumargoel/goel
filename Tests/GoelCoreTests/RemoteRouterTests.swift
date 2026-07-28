import XCTest
@testable import GoelCore

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
    private(set) var addedNetworks: [NetworkSelection?] = []
    private(set) var aggregationUpdates: [(Bool?, [String]?, Int?)] = []
    var network = RemoteNetworkState()

    func remoteAdd(source: DownloadSource) async { added.append(source) }
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async {
        added.append(source)
        addedNetworks.append(nil)
    }
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network selection: NetworkSelection?) async {
        added.append(source)
        addedNetworks.append(selection)
    }
    func networkState() async -> RemoteNetworkState { network }
    func updateAggregation(enabled: Bool?, adapterIds: [String]?, streams: Int?) async {
        aggregationUpdates.append((enabled, adapterIds, streams))
        if let enabled { network.aggregation = enabled }
        if let adapterIds { network.selected = adapterIds }
        if let streams { network.streamsPerAdapter = streams }
    }
    var folderHome: String?
    var folderDefault: String = "/home/goel/Downloads"
    var subfolders: [String: [String]] = [:]
    private(set) var createdFolders: [(name: String, parent: String?)] = []

    func folderListing(_ path: String?) async -> RemoteFolderListing? {
        guard let folderHome else { return nil }
        let target = (path?.isEmpty == false) ? path! : folderDefault
        guard let children = subfolders[target] else { return nil }
        return RemoteFolderListing(
            path: target,
            parent: target == "/" ? nil : (target as NSString).deletingLastPathComponent,
            folders: children.map {
                .init(name: $0, path: (target as NSString).appendingPathComponent($0))
            },
            writable: true,
            home: folderHome,
            defaultFolder: folderDefault,
            places: [.init(name: "Home", path: folderHome)])
    }

    func createFolder(named name: String, in parent: String?) async -> String? {
        guard folderHome != nil else { return nil }
        createdFolders.append((name, parent))
        return ((parent ?? folderDefault) as NSString).appendingPathComponent(name)
    }

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

    private func post(_ path: String, _ body: String) -> RemoteRequest {
        request("POST \(path)?token=secret HTTP/1.1\r\nContent-Type: application/json\r\n\r\n\(body)")
    }

    func testAddCarriesTheNetworkSelection() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(post(
            "/api/add", "{\"url\":\"https://e/x.bin\",\"network\":\"single:eth0\"}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.addedNetworks, [.single("eth0")])
    }

    func testAddWithoutANetworkFieldMeansAuto() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(post("/api/add", "{\"url\":\"https://e/x.bin\"}"))
        XCTAssertEqual(backend.addedNetworks, [nil])
    }

    /// A typo must not silently become "use every interface".
    func testAddWithAMalformedNetworkSpecIsRefused() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(post(
            "/api/add", "{\"url\":\"https://e/x.bin\",\"network\":\"single:\"}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(backend.added.isEmpty, "nothing may be queued when the spec is bad")
    }

    func testNetworkStateIsServed() async {
        let backend = FakeRemoteBackend()
        backend.network = RemoteNetworkState(
            aggregation: true, streamsPerAdapter: 3, selected: ["eth0"],
            reason: nil, locked: true,
            adapters: [.init(name: "eth0", label: "eth0", type: "wired",
                             ipv4: "10.0.0.2", expensive: false, eligible: true)])
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(request("GET /api/network?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(out.contains("\"streamsPerAdapter\":3"))
        XCTAssertTrue(out.contains("\"locked\":true"))
        XCTAssertTrue(out.contains("\"eth0\""))
    }

    func testAggregationUpdateAppliesAndEchoesTheResult() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(post(
            "/api/network", "{\"aggregation\":true,\"adapters\":[\"eth0\"],\"streams\":4}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.aggregationUpdates.count, 1)
        XCTAssertEqual(backend.aggregationUpdates.first?.0, true)
        XCTAssertEqual(backend.aggregationUpdates.first?.1, ["eth0"])
        XCTAssertEqual(backend.aggregationUpdates.first?.2, 4)
        XCTAssertTrue(out.contains("\"aggregation\":true"))
    }

    /// `GET` answers with `streamsPerAdapter`, so posting that object back must work — decoding only `streams` silently drops the field and its range check.
    func testAggregationUpdateAcceptsTheResponseSpellingOfStreams() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(post("/api/network", "{\"streamsPerAdapter\":5}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.aggregationUpdates.first?.2, 5)

        let bad = str(await router.handle(post("/api/network", "{\"streamsPerAdapter\":99}")))
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 400"))
        XCTAssertEqual(backend.aggregationUpdates.count, 1, "the bad one must not apply")
    }

    func testAggregationUpdateRejectsBadInputWithoutApplyingAnything() async {
        for body in ["{\"adapters\":[\"eth0 bad\"]}", "{\"streams\":0}", "{\"streams\":99}"] {
            let backend = FakeRemoteBackend()
            let router = RemoteRouter(backend: backend, token: "secret")
            let out = str(await router.handle(post("/api/network", body)))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(body) should be refused")
            XCTAssertTrue(backend.aggregationUpdates.isEmpty)
        }
    }

    /// Every mutation is a POST and read-only blocks POSTs, but assert it covers this one rather than trusting the blanket rule stays blanket.
    func testReadOnlyBlocksTheAggregationWrite() async {
        let backend = FakeRemoteBackend()
        let router = RemoteRouter(backend: backend, config: .init(
            token: "secret", readOnly: true))
        let out = str(await router.handle(post("/api/network", "{\"aggregation\":true}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(backend.aggregationUpdates.isEmpty)
    }

    private func folderBackend() -> FakeRemoteBackend {
        let backend = FakeRemoteBackend()
        backend.folderHome = "/home/goel"
        backend.folderDefault = "/home/goel/Downloads"
        backend.subfolders = [
            "/": ["home"],
            "/home": ["goel"],
            "/home/goel": ["Downloads", "Documents"],
            "/home/goel/Downloads": ["Linux"],
            "/home/goel/Downloads/Linux": ["ISOs"],
        ]
        return backend
    }

    func testFolderListingDefaultsToTheConfiguredDownloadsFolder() async throws {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request("GET /api/folders?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(out.contains("\"path\":\"\\/home\\/goel\\/Downloads\""), out)
        XCTAssertTrue(out.contains("\"name\":\"Linux\""), out)
        XCTAssertTrue(out.contains("\"home\":\"\\/home\\/goel\""), out)
    }

    func testTheDownloadsFolderOffersAWayUp() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request("GET /api/folders?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.contains("\"parent\":\"\\/home\\/goel\""), out)
    }

    func testFolderListingFollowsThePathQuery() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request(
            "GET /api/folders?token=secret&path=%2Fhome%2Fgoel%2FDownloads%2FLinux HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.contains("\"name\":\"ISOs\""), out)
        XCTAssertTrue(out.contains("\"parent\":\"\\/home\\/goel\\/Downloads\""), out)
    }

    /// Outside the downloads folder is now ordinary browsing, not a refusal.
    func testFolderListingReachesOutsideTheDownloadsFolder() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request(
            "GET /api/folders?token=secret&path=%2Fhome%2Fgoel HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertTrue(out.contains("\"name\":\"Documents\""), out)
    }

    func testOnlyTheFilesystemRootHasNoParent() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request(
            "GET /api/folders?token=secret&path=%2F HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertFalse(out.contains("\"parent\""), out)
    }

    func testAMissingFolderIs404() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let out = str(await router.handle(request(
            "GET /api/folders?token=secret&path=%2Fnope HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 404"), out)
    }

    func testCreateFolderPassesTheNameAndParentThrough() async {
        let backend = folderBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = str(await router.handle(post(
            "/api/folder", "{\"name\":\"ISOs\",\"parent\":\"/home/goel/Documents\"}")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK"), out)
        XCTAssertTrue(out.contains("\"path\":\"\\/home\\/goel\\/Documents\\/ISOs\""), out)
        XCTAssertEqual(backend.createdFolders.count, 1)
        XCTAssertEqual(backend.createdFolders.first?.name, "ISOs")
    }

    func testCreateFolderTrimsTheNameBeforeItReachesTheBackend() async {
        let backend = folderBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        _ = await router.handle(post("/api/folder", "{\"name\":\"  ISOs  \"}"))
        XCTAssertEqual(backend.createdFolders.first?.name, "ISOs",
                       "a trailing space would make a folder nobody can name again")
    }

    func testCreateFolderRefusesTraversalWithoutTouchingTheBackend() async {
        for name in ["..", "../etc", "a/b", ".hidden", ""] {
            let backend = folderBackend()
            let router = RemoteRouter(backend: backend, token: "secret")
            let out = str(await router.handle(post(
                "/api/folder", "{\"name\":\"\(name)\"}")))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(name): \(out)")
            XCTAssertTrue(backend.createdFolders.isEmpty, name)
        }
    }

    func testReadOnlyBlocksFolderCreationButNotBrowsing() async {
        let backend = folderBackend()
        let router = RemoteRouter(backend: backend, config: .init(token: "secret", readOnly: true))

        let created = str(await router.handle(post("/api/folder", "{\"name\":\"ISOs\"}")))
        XCTAssertTrue(created.hasPrefix("HTTP/1.1 403"), created)
        XCTAssertTrue(backend.createdFolders.isEmpty)

        let listed = str(await router.handle(request("GET /api/folders?token=secret HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(listed.hasPrefix("HTTP/1.1 200 OK"), listed)
    }

    func testFolderRoutesNeedAuth() async {
        let router = RemoteRouter(backend: folderBackend(), token: "secret")
        let listed = str(await router.handle(request("GET /api/folders HTTP/1.1\r\n\r\n")))
        XCTAssertTrue(listed.hasPrefix("HTTP/1.1 401"), listed)
        let created = str(await router.handle(request(
            "POST /api/folder HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"name\":\"x\"}")))
        XCTAssertTrue(created.hasPrefix("HTTP/1.1 401"), created)
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
