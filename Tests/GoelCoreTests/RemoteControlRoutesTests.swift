import XCTest
@testable import GoelCore

/// Records what the queue-control, history and schedule routes asked of the core.
private final class ControlBackend: RemoteBackend, @unchecked Sendable {
    private(set) var sequential: [(Bool, UUID)] = []
    private(set) var limits: [(Int64?, UUID)] = []
    private(set) var starts: [(Date?, UUID)] = []
    private(set) var moves: [([UUID], QueueOrder.Placement)] = []
    private(set) var tags: [([String], UUID)] = []
    private(set) var filePriorities: [(FilePriority, Int)] = []
    private(set) var removedHistory: [UUID] = []
    private(set) var clearedHistory = false
    var entries: [HistoryEntry] = []
    var schedule: RemoteScheduleState? = RemoteScheduleState(
        enabled: false, startMinute: 60, endMinute: 420, days: [1, 2, 3, 4, 5, 6, 7],
        profile: "", profiles: ["Low", "Night"])

    func taskSnapshot() async -> [DownloadTask] { [] }
    var tasks: [UUID: DownloadTask] = [:]
    func task(_ id: UUID) async -> DownloadTask? { tasks[id] }
    func pauseAll() async {}
    func resumeAll() async {}
    func pause(_ id: UUID) async {}
    func resume(_ id: UUID) async {}
    func retry(_ id: UUID) async {}
    func remove(_ id: UUID, deleteData: Bool) async {}
    func forceRecheck(_ id: UUID) async {}
    func setSequential(_ on: Bool, task id: UUID) async { sequential.append((on, id)) }
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: UUID) async {
        filePriorities.append((priority, fileID))
    }
    func remoteAdd(source: DownloadSource) async {}
    func remoteAdd(source: DownloadSource, saveDirectory: String?,
                   priority: FilePriority, startPaused: Bool) async {}
    func history(limit: Int) async -> [HistoryEntry] { entries }
    func removeHistoryEntry(_ id: UUID) async { removedHistory.append(id) }
    func clearHistory() async { clearedHistory = true }

    func setTaskSpeedLimit(_ bytesPerSec: Int64?, task id: UUID) async { limits.append((bytesPerSec, id)) }
    func setTags(_ tags: [String], task id: UUID) async { self.tags.append((tags, id)) }
    func setScheduledStart(_ date: Date?, task id: UUID) async { starts.append((date, id)) }
    func remoteMove(_ ids: [UUID], to placement: QueueOrder.Placement) async { moves.append((ids, placement)) }
    private(set) var addedTrackers: [String] = []
    private(set) var removedTrackers: Set<String> = []
    var trackerURLs: Set<String> = ["udp://old.example:80/announce"]
    func addTrackers(_ urls: [String], task id: UUID) async -> Int { addedTrackers += urls; return urls.count }
    func removeTrackers(_ urls: Set<String>, task id: UUID) async { removedTrackers.formUnion(urls) }
    func editTracker(_ old: String, to new: String, task id: UUID) async -> Bool {
        guard trackerURLs.remove(old) != nil else { return false }
        trackerURLs.insert(new)
        return true
    }
    var appSettings = AppSettings()
    var allowedFolders: Set<String> = ["/srv/downloads"]
    func settingsState() async -> RemoteSettingsState? { RemoteSettingsState(appSettings) }
    func updateSettings(_ update: RemoteSettingsUpdate) async -> RemoteSettingsState? {
        update.apply(to: &appSettings)
        return RemoteSettingsState(appSettings)
    }
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool { allowedFolders.contains(folder) }
    func scheduleState() async -> RemoteScheduleState? { schedule }
    func updateSchedule(_ update: RemoteScheduleUpdate) async -> RemoteScheduleState? {
        guard var state = schedule else { return nil }
        if let enabled = update.enabled { state.enabled = enabled }
        if let start = update.startMinute { state.startMinute = start }
        if let end = update.endMinute { state.endMinute = end }
        if let days = update.days { state.days = Array(Set(days)).sorted() }
        if let profile = update.profile { state.profile = profile }
        schedule = state
        return state
    }
}

final class RemoteControlRoutesTests: XCTestCase {

    private let id = UUID()

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    private func raw(_ method: String, _ path: String, json: String? = nil, auth: Bool = true,
                     origin: String? = nil) -> RemoteRequest {
        let body = Data((json ?? "").utf8)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost:8080\r\n"
        if auth { head += "Authorization: Bearer secret\r\n" }
        if let origin { head += "Origin: \(origin)\r\n" }
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return RemoteRequest(raw: Data(head.utf8) + body)
    }

    private func send(_ request: RemoteRequest, _ backend: ControlBackend,
                      readOnly: Bool = false) async -> String {
        let router = RemoteRouter(backend: backend, config: .init(token: "secret", readOnly: readOnly))
        return str(await router.handle(request))
    }

    /// Every new write route, in a form that would succeed: the gates must stop each one.
    private func writes(auth: Bool = true) -> [RemoteRequest] {
        let q = id.uuidString
        return [
            raw("POST", "/api/sequential?id=\(q)&on=1", auth: auth),
            raw("POST", "/api/speed-limit?id=\(q)&bps=1000", auth: auth),
            raw("POST", "/api/start-at?id=\(q)&at=clear", auth: auth),
            raw("POST", "/api/move", json: #"{"ids":["\#(q)"],"to":"top"}"#, auth: auth),
            raw("POST", "/api/tags", json: #"{"id":"\#(q)","tags":["tv"]}"#, auth: auth),
            raw("POST", "/api/file-priorities", json: #"{"id":"\#(q)","files":[0],"prio":"skip"}"#, auth: auth),
            raw("POST", "/api/history-remove-many", json: #"{"ids":["\#(q)"]}"#, auth: auth),
            raw("POST", "/api/history-clear", json: "{}", auth: auth),
            raw("POST", "/api/schedule", json: #"{"enabled":true}"#, auth: auth),
            raw("POST", "/api/settings", json: #"{"bittorrent":{"dht":false}}"#, auth: auth),
            raw("POST", "/api/trackers", json: #"{"id":"\#(q)","add":["udp://t.example:80/announce"]}"#, auth: auth),
        ]
    }

    // MARK: - Gates

    func testEveryWriteRouteNeedsAuth() async {
        for request in writes(auth: false) {
            let out = await send(request, ControlBackend())
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 401"), "\(request.path): \(out.prefix(40))")
        }
        let get = await send(raw("GET", "/api/schedule", auth: false), ControlBackend())
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 401"))
    }

    func testReadOnlyRefusesEveryWriteRouteButServesTheSchedule() async {
        let backend = ControlBackend()
        for request in writes() {
            let out = await send(request, backend, readOnly: true)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), "\(request.path): \(out.prefix(40))")
        }
        XCTAssertTrue(backend.sequential.isEmpty && backend.limits.isEmpty && backend.moves.isEmpty)
        XCTAssertTrue(backend.tags.isEmpty && backend.removedHistory.isEmpty && !backend.clearedHistory)
        XCTAssertTrue(backend.addedTrackers.isEmpty)
        let get = await send(raw("GET", "/api/schedule"), backend, readOnly: true)
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 200 OK"))
    }

    func testCrossSiteWritesAreRefused() async {
        let backend = ControlBackend()
        let out = await send(raw("POST", "/api/speed-limit?id=\(id.uuidString)&bps=5",
                                 origin: "https://evil.example"), backend)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(backend.limits.isEmpty)
    }

    // MARK: - Routes

    func testSequentialAndSpeedLimit() async {
        let backend = ControlBackend()
        _ = await send(raw("POST", "/api/sequential?id=\(id.uuidString)&on=1"), backend)
        _ = await send(raw("POST", "/api/speed-limit?id=\(id.uuidString)&bps=0"), backend)
        _ = await send(raw("POST", "/api/speed-limit?id=\(id.uuidString)&bps=2048"), backend)
        XCTAssertEqual(backend.sequential.first?.0, true)
        XCTAssertEqual(backend.limits.map(\.0), [nil, 2048], "0 lifts the cap")

        for bad in ["bps=-1", "bps=abc", "bps=999999999999999", "bps="] {
            let out = await send(raw("POST", "/api/speed-limit?id=\(id.uuidString)&\(bad)"), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), bad)
        }
        let noID = await send(raw("POST", "/api/sequential?id=nope&on=1"), backend)
        XCTAssertTrue(noID.hasPrefix("HTTP/1.1 400"))
        XCTAssertEqual(backend.limits.count, 2)
    }

    func testStartAtValidatesTheWindow() async {
        let backend = ControlBackend()
        let soon = Int(Date().timeIntervalSince1970) + 3600
        _ = await send(raw("POST", "/api/start-at?id=\(id.uuidString)&at=\(soon)"), backend)
        _ = await send(raw("POST", "/api/start-at?id=\(id.uuidString)&at=clear"), backend)
        XCTAssertEqual(backend.starts.count, 2)
        XCTAssertEqual(backend.starts[0].0.map { Int($0.timeIntervalSince1970) }, soon)
        XCTAssertNil(backend.starts[1].0)

        let past = Int(Date().timeIntervalSince1970) - 7200
        let far = Int(Date().timeIntervalSince1970) + 400 * 86400
        for at in ["\(past)", "\(far)", "tomorrow", "nan"] {
            let out = await send(raw("POST", "/api/start-at?id=\(id.uuidString)&at=\(at)"), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), at)
        }
        XCTAssertEqual(backend.starts.count, 2)
    }

    func testMove() async {
        let backend = ControlBackend()
        let anchor = UUID()
        let out = await send(raw("POST", "/api/move",
                                 json: #"{"ids":["\#(id.uuidString)"],"to":"after","anchor":"\#(anchor.uuidString)"}"#), backend)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(backend.moves.first?.1, .after(anchor))

        let bad = [
            #"{"ids":[],"to":"top"}"#,
            #"{"ids":["\#(id.uuidString)"],"to":"middle"}"#,
            #"{"ids":["\#(id.uuidString)"],"to":"before"}"#,
            #"{"ids":["x"],"to":"top"}"#,
            "not json",
        ]
        for json in bad {
            let refused = await send(raw("POST", "/api/move", json: json), backend)
            XCTAssertTrue(refused.hasPrefix("HTTP/1.1 400"), json)
        }
        XCTAssertEqual(backend.moves.count, 1)
    }

    func testTagsAreCleanedAndBounded() async {
        let backend = ControlBackend()
        _ = await send(raw("POST", "/api/tags", json: #"{"id":"\#(id.uuidString)","tags":[" tv ","","linux"]}"#), backend)
        XCTAssertEqual(backend.tags.first?.0, ["tv", "linux"])

        let tooMany = (0...RemoteRouter.maxTags).map { "\"t\($0)\"" }.joined(separator: ",")
        let long = String(repeating: "x", count: RemoteRouter.maxTagLength + 1)
        for tags in [tooMany, "\"\(long)\"", #""a\u0007b""#] {
            let out = await send(raw("POST", "/api/tags", json: #"{"id":"\#(id.uuidString)","tags":[\#(tags)]}"#), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), tags)
        }
        XCTAssertEqual(backend.tags.count, 1)
    }

    private func torrent(files count: Int) -> DownloadTask {
        var task = DownloadTask(id: id, source: .url(URL(string: "https://e/pack")!),
                                name: "pack", saveDirectory: "/tmp", status: .downloading)
        task.files = (0..<count).map { TransferFile(id: $0, path: "pack/\($0).mkv", length: 100) }
        return task
    }

    func testFilePrioritiesInOneRequest() async {
        let backend = ControlBackend()
        backend.tasks[id] = torrent(files: 3)
        _ = await send(raw("POST", "/api/file-priorities",
                           json: #"{"id":"\#(id.uuidString)","files":[0,2,2],"prio":"skip"}"#), backend)
        XCTAssertEqual(backend.filePriorities.map(\.1), [0, 2], "duplicates dropped")
        XCTAssertTrue(backend.filePriorities.allSatisfy { $0.0 == .skip })

        for json in [#"{"id":"\#(id.uuidString)","files":[0],"prio":"max"}"#,
                     #"{"id":"\#(id.uuidString)","files":[],"prio":"low"}"#,
                     #"{"id":"\#(id.uuidString)","files":[3],"prio":"low"}"#,
                     #"{"id":"\#(id.uuidString)","files":[0,999999],"prio":"low"}"#,
                     #"{"id":"\#(id.uuidString)","files":[-1],"prio":"low"}"#] {
            let out = await send(raw("POST", "/api/file-priorities", json: json), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), json)
        }
        XCTAssertEqual(backend.filePriorities.count, 2, "a refused request changes nothing")

        backend.tasks = [:]
        let gone = await send(raw("POST", "/api/file-priorities",
                                  json: #"{"id":"\#(id.uuidString)","files":[0],"prio":"low"}"#), backend)
        XCTAssertTrue(gone.hasPrefix("HTTP/1.1 404"))
    }

    func testSettingsRoundTripAndAreValidatedAtTheBoundary() async throws {
        let backend = ControlBackend()
        let before = await send(raw("GET", "/api/settings"), backend)
        XCTAssertTrue(before.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(before.contains(#""encryptionMode":"prefer""#), before)

        let ok = await send(raw("POST", "/api/settings", json: """
            {"general":{"defaultSaveDirectory":"/srv/downloads","existingFileReaction":"overwrite","maxSimultaneousDownloads":5},
             "bittorrent":{"encryptionMode":"require","dht":false,"utp":false}}
            """), backend)
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertEqual(backend.appSettings.defaultSaveDirectory, "/srv/downloads")
        XCTAssertEqual(backend.appSettings.existingFileReaction, "overwrite")
        XCTAssertEqual(backend.appSettings.selectedProfile.maxSimultaneousDownloads, 5)
        XCTAssertEqual(backend.appSettings.btEncryptionMode, "require")
        XCTAssertFalse(backend.appSettings.btEnableDHT)
        XCTAssertFalse(backend.appSettings.btEnableUTP)
        XCTAssertTrue(backend.appSettings.btEnablePeX, "an omitted field keeps its value")

        for bad in [#"{"general":{"maxSimultaneousDownloads":0}}"#,
                    #"{"general":{"maxSimultaneousDownloads":99}}"#,
                    #"{"general":{"defaultSaveDirectory":"relative/path"}}"#,
                    #"{"general":{"defaultSaveDirectory":""}}"#,
                    #"{"general":{"defaultFolderRule":"nope"}}"#,
                    #"{"general":{"existingFileReaction":"delete"}}"#,
                    #"{"bittorrent":{"encryptionMode":"maybe"}}"#,
                    #"{"bittorrent":{"dht":"yes"}}"#,
                    "not json"] {
            let out = await send(raw("POST", "/api/settings", json: bad), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(bad) -> \(out.prefix(30))")
        }
        let forbidden = await send(raw("POST", "/api/settings",
                                       json: #"{"general":{"defaultSaveDirectory":"/etc"}}"#), backend)
        XCTAssertTrue(forbidden.hasPrefix("HTTP/1.1 403"), forbidden)
        XCTAssertEqual(backend.appSettings.defaultSaveDirectory, "/srv/downloads")

        let unauth = await send(raw("GET", "/api/settings", auth: false), backend)
        XCTAssertTrue(unauth.hasPrefix("HTTP/1.1 401"))
        let readOnly = await send(raw("POST", "/api/settings", json: "{}"), backend, readOnly: true)
        XCTAssertTrue(readOnly.hasPrefix("HTTP/1.1 403"))
    }

    func testHistoryPagingIsOptionalAndValidated() async {
        let backend = ControlBackend()
        backend.entries = (0..<5).map {
            HistoryEntry(id: UUID(), name: "f\($0)", locator: "https://x/\($0)", kind: .http,
                         totalBytes: 1, savePath: "/tmp/f\($0)", completedAt: Date())
        }
        func page(_ query: String) async -> [String] {
            let out = await send(raw("GET", "/api/history\(query)"), backend)
            return (0..<5).map { "f\($0)" }.filter { out.contains("\"name\":\"\($0)\"") }
        }
        let everything = await page("")
        let firstTwo = await page("?limit=2")
        let tail = await page("?limit=2&offset=3")
        let past = await page("?offset=9")
        XCTAssertEqual(everything, ["f0", "f1", "f2", "f3", "f4"])
        XCTAssertEqual(firstTwo, ["f0", "f1"])
        XCTAssertEqual(tail, ["f3", "f4"])
        XCTAssertEqual(past, [])
        for bad in ["limit=0", "limit=x", "offset=-1", "offset=1.5"] {
            let out = await send(raw("GET", "/api/history?\(bad)"), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), bad)
        }
    }

    func testHistoryBulkRemoveAndClearOlderThan() async {
        let backend = ControlBackend()
        let old = HistoryEntry(id: UUID(), name: "old", locator: "https://x/old", kind: .http,
                               totalBytes: 1, savePath: "/tmp/old", completedAt: Date().addingTimeInterval(-10 * 86400))
        let fresh = HistoryEntry(id: UUID(), name: "new", locator: "https://x/new", kind: .http,
                                 totalBytes: 1, savePath: "/tmp/new", completedAt: Date())
        backend.entries = [old, fresh]

        let out = await send(raw("POST", "/api/history-clear", json: #"{"olderThan":604800}"#), backend)
        XCTAssertTrue(out.contains(#""removed":1"#), out)
        XCTAssertEqual(backend.removedHistory, [old.id])
        XCTAssertFalse(backend.clearedHistory)

        _ = await send(raw("POST", "/api/history-clear", json: "{}"), backend)
        XCTAssertTrue(backend.clearedHistory)

        _ = await send(raw("POST", "/api/history-remove-many", json: #"{"ids":["\#(fresh.id.uuidString)"]}"#), backend)
        XCTAssertEqual(backend.removedHistory.last, fresh.id)

        for (path, json) in [("/api/history-clear", #"{"olderThan":-5}"#),
                             ("/api/history-remove-many", #"{"ids":["nope"]}"#),
                             ("/api/history-remove-many", #"{"ids":[]}"#)] {
            let refused = await send(raw("POST", path, json: json), backend)
            XCTAssertTrue(refused.hasPrefix("HTTP/1.1 400"), json)
        }
    }

    func testScheduleReadWriteAndValidation() async throws {
        let backend = ControlBackend()
        let get = await send(raw("GET", "/api/schedule"), backend)
        XCTAssertTrue(get.contains(#""profiles":["Low","Night"]"#), get)

        let post = await send(raw("POST", "/api/schedule",
                                  json: #"{"enabled":true,"startMinute":1320,"endMinute":360,"days":[2,2,1],"profile":"Night"}"#), backend)
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 200"), post)
        XCTAssertEqual(backend.schedule?.days, [1, 2])
        XCTAssertEqual(backend.schedule?.profile, "Night")

        let bad = [#"{"startMinute":1440}"#, #"{"endMinute":-1}"#, #"{"days":[]}"#,
                   #"{"days":[0]}"#, #"{"profile":"Nope"}"#, "[]"]
        for json in bad {
            let out = await send(raw("POST", "/api/schedule", json: json), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), json)
        }

        backend.schedule = nil
        let missing = await send(raw("GET", "/api/schedule"), backend)
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 404"))
    }

    func testTrackersAddRemoveEdit() async throws {
        let backend = ControlBackend()
        let body = #"{"id":"\#(id.uuidString)","add":[" https://a.example/announce "],"remove":["udp://gone.example:1/announce"],"edit":{"old":"udp://old.example:80/announce","new":"udp://new.example:80/announce"}}"#
        let out = await send(raw("POST", "/api/trackers", json: body), backend)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200"), out)
        XCTAssertTrue(out.contains(#""added":1"#) && out.contains(#""edited":true"#), out)
        XCTAssertEqual(backend.addedTrackers, ["https://a.example/announce"])
        XCTAssertEqual(backend.removedTrackers, ["udp://gone.example:1/announce"])
        XCTAssertTrue(backend.trackerURLs.contains("udp://new.example:80/announce"))
    }

    func testTrackersRefuseInvalidURLsWithoutChangingAnything() async {
        let backend = ControlBackend()
        let bad = [
            #"{"id":"\#(id.uuidString)","add":["udp://ok.example/announce","javascript:alert(1)"]}"#,
            #"{"id":"\#(id.uuidString)","add":["ftp://x.example/announce"]}"#,
            #"{"id":"\#(id.uuidString)","edit":{"old":"udp://old.example:80/announce","new":"not a url"}}"#,
            #"{"id":"\#(id.uuidString)"}"#,
            #"{"id":"nope","add":["udp://ok.example/announce"]}"#,
        ]
        for json in bad {
            let out = await send(raw("POST", "/api/trackers", json: json), backend)
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), json)
        }
        XCTAssertTrue(backend.addedTrackers.isEmpty)
        let missing = await send(raw("POST", "/api/trackers", json:
            #"{"id":"\#(id.uuidString)","edit":{"old":"udp://nope.example/announce","new":"udp://x.example/announce"}}"#), backend)
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 404"))
    }

    func testAddRefusesAStartTimeInThePast() async {
        let backend = ControlBackend()
        let out = await send(raw("POST", "/api/add", json: #"{"url":"https://example.com/a.iso","startAt":5}"#), backend)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), out)
    }

    // MARK: - PWA shell

    func testPWAAssetsAreServedBeforeAuth() throws {
        let manifest = try XCTUnwrap(RemoteRouter.staticAsset(path: "/manifest.webmanifest"))
        XCTAssertTrue(str(manifest).contains("application/manifest+json"))
        XCTAssertTrue(str(manifest).contains(#""display": "standalone""#) || str(manifest).contains(#""display":"standalone""#))

        let worker = try XCTUnwrap(RemoteRouter.staticAsset(path: "/sw.js"))
        XCTAssertTrue(str(worker).contains("Service-Worker-Allowed: /"))

        let icon = try XCTUnwrap(RemoteRouter.staticAsset(path: "/icons/icon-192.png"))
        XCTAssertTrue(str(icon).contains("image/png"))
        for path in ["/icons/../secret.png", "/icons/nope.png"] {
            let out = RemoteRouter.staticAsset(path: path).map(str) ?? ""
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 404"), path)
        }
    }

    func testManifestIsInstallableShareableAndKnowsItsDarkCanvas() throws {
        let out = str(try XCTUnwrap(RemoteRouter.staticAsset(path: "/manifest.webmanifest")))
        let body = try XCTUnwrap(out.components(separatedBy: "\r\n\r\n").last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "/")
        XCTAssertFalse((json["description"] as? String ?? "").isEmpty)
        let dark = try XCTUnwrap(json["color_scheme_dark"] as? [String: String])
        XCTAssertEqual(dark["background_color"], RemoteRouter.darkCanvas)
        XCTAssertEqual(json["background_color"] as? String, RemoteRouter.lightCanvas)

        let share = try XCTUnwrap(json["share_target"] as? [String: Any])
        XCTAssertEqual(share["method"] as? String, "GET")
        XCTAssertEqual(share["action"] as? String, "/")
        XCTAssertEqual((share["params"] as? [String: String])?["url"], "url")

        let shortcuts = try XCTUnwrap(json["shortcuts"] as? [[String: Any]])
        XCTAssertEqual(shortcuts.first?["url"] as? String, "/?add=1")

        // Every icon the manifest names is servable; the maskable one is its own full-bleed file.
        let icons = try XCTUnwrap(json["icons"] as? [[String: String]])
        XCTAssertTrue(icons.contains { $0["purpose"] == "maskable" && $0["src"] == "/icons/icon-maskable-512.png" })
        for icon in icons {
            let src = try XCTUnwrap(icon["src"])
            XCTAssertTrue(str(try XCTUnwrap(RemoteRouter.staticAsset(path: src))).hasPrefix("HTTP/1.1 200"), src)
        }
    }

    func testOfflinePageUsesTheAppCanvasAndSpeaksGerman() {
        let worker = PortalBundle.serviceWorker
        XCTAssertTrue(worker.contains(RemoteRouter.lightCanvas))
        XCTAssertTrue(worker.contains(RemoteRouter.darkCanvas))
        XCTAssertTrue(worker.contains("navigator.language"))
        XCTAssertTrue(worker.contains("Goel°-Server nicht erreichbar"))
    }

    func testPageShellLinksTheManifestAndCarriesTheLanguage() {
        let page = RemoteRouter.page(config: .init(token: "secret", theme: "nord"))
        XCTAssertTrue(page.contains(#"rel="manifest""#))
        XCTAssertTrue(page.contains(##"name="theme-color" content="#121e18""##))
        XCTAssertTrue(page.contains(#""language":"#) || page.contains(#""language" :"#))
    }

    /// `auto` follows the device, so the title-bar colour is given per colour scheme; an unknown
    /// token can't reach the markup and falls back to `auto`.
    func testPageShellThemeColourFollowsTheDeviceForAuto() {
        let auto = RemoteRouter.page(config: .init(token: "secret", theme: "auto"))
        XCTAssertTrue(auto.contains(#"data-theme="auto""#))
        XCTAssertTrue(auto.contains(##"media="(prefers-color-scheme: light)" content="#f1f7f2""##))
        XCTAssertTrue(auto.contains(##"media="(prefers-color-scheme: dark)" content="#121e18""##))

        let light = RemoteRouter.page(config: .init(token: "secret", theme: "light"))
        XCTAssertTrue(light.contains(##"name="theme-color" content="#f1f7f2""##))
        XCTAssertFalse(light.contains("prefers-color-scheme"))

        let dark = RemoteRouter.page(config: .init(token: "secret", theme: "dark"))
        XCTAssertTrue(dark.contains(##"name="theme-color" content="#121e18""##))
        XCTAssertFalse(dark.contains("prefers-color-scheme"))

        // The portal treats the old Frost pair as `auto`, so the title bar follows the device too.
        for legacy in ["frost-light", "frost-dark"] {
            let page = RemoteRouter.page(config: .init(token: "secret", theme: legacy))
            XCTAssertTrue(page.contains(##"media="(prefers-color-scheme: light)" content="#f1f7f2""##), legacy)
            XCTAssertTrue(page.contains(##"media="(prefers-color-scheme: dark)" content="#121e18""##), legacy)
        }

        // A portal configured without a theme follows the device.
        XCTAssertEqual(RemoteRouter.Config(token: "secret").theme, "auto")

        let hostile = RemoteRouter.page(config: .init(token: "secret", theme: #""><script>x</script>"#))
        XCTAssertTrue(hostile.contains(#"data-theme="auto""#))
        XCTAssertFalse(hostile.contains("<script>x</script>"))
    }
}

final class RemoteScheduleUpdateTests: XCTestCase {
    /// Only the schedule fields move: a setting changed elsewhere after the portal loaded survives.
    func testUpdateScheduleTouchesOnlyScheduleFields() async throws {
        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: try PersistenceStore())
        await manager.setSpeedLimitEnabled(true)
        let before = await manager.settings

        let state = await manager.updateSchedule(RemoteScheduleUpdate(
            enabled: true, startMinute: 1320, endMinute: 420, days: [2, 3]))
        let after = await manager.settings

        XCTAssertEqual(state?.startMinute, 1320)
        XCTAssertEqual(after.scheduleDays, [2, 3])
        XCTAssertTrue(after.speedLimitEnabled, "an unrelated setting must not be reverted")
        XCTAssertEqual(after.defaultSaveDirectory, before.defaultSaveDirectory)
    }
}
