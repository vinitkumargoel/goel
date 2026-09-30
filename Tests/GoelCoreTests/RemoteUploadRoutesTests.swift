import XCTest
#if !os(Linux)
import Network
#endif
@testable import GoelCore

/// A backend that only speaks bandwidth and torrent uploads; the rest are inert.
private final class UploadBackend: RemoteBackend, @unchecked Sendable {
    var bandwidth: RemoteBandwidthState? = RemoteBandwidthState(
        enabled: true, selected: "Medium",
        profiles: [.init(name: "Low", downBytesPerSec: 1_000, upBytesPerSec: 500),
                   .init(name: "Medium", downBytesPerSec: 5_000, upBytesPerSec: nil)])
    private(set) var bandwidthUpdates: [RemoteBandwidthUpdate] = []
    private(set) var torrents: [(data: Data, name: String, dir: String?, paused: Bool)] = []
    private(set) var networks: [NetworkSelection?] = []
    var failNames: Set<String> = []
    var allowedFolders: Set<String>?

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
    func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool {
        allowedFolders?.contains(folder) ?? true
    }

    func bandwidthState() async -> RemoteBandwidthState? { bandwidth }
    func updateBandwidth(_ update: RemoteBandwidthUpdate) async -> RemoteBandwidthState? {
        bandwidthUpdates.append(update)
        guard var state = bandwidth else { return nil }
        if let enabled = update.enabled { state.enabled = enabled }
        if let selected = update.selected { state.selected = selected }
        for caps in update.profiles ?? [] {
            guard let i = state.profiles.firstIndex(where: { $0.name == caps.name }) else { continue }
            if let down = caps.downBytesPerSec { state.profiles[i].downBytesPerSec = down }
            if let up = caps.upBytesPerSec { state.profiles[i].upBytesPerSec = up }
        }
        bandwidth = state
        return state
    }

    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool) async throws -> UUID? {
        if failNames.contains(name) { throw RemoteTorrentUpload.Failure.rejected("engine said no") }
        torrents.append((data, name, saveDirectory, startPaused))
        return UUID()
    }

    func remoteAddTorrent(_ data: Data, named name: String, saveDirectory: String?,
                          priority: FilePriority, startPaused: Bool,
                          network: NetworkSelection?) async throws -> UUID? {
        networks.append(network)
        return try await remoteAddTorrent(data, named: name, saveDirectory: saveDirectory,
                                          priority: priority, startPaused: startPaused)
    }
}

final class RemoteUploadRoutesTests: XCTestCase {

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    private func jsonBody(_ response: Data) throws -> [String: Any] {
        let text = str(response)
        let body = try XCTUnwrap(text.range(of: "\r\n\r\n")).upperBound
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[body...].utf8)) as? [String: Any])
    }

    private func raw(_ method: String, _ path: String, type: String? = nil, body: Data = Data()) -> RemoteRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nAuthorization: Bearer secret\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return RemoteRequest(raw: Data(head.utf8) + body)
    }

    // MARK: - /api/bandwidth

    func testGetBandwidthEncodesNullForUnlimited() async throws {
        let router = RemoteRouter(backend: UploadBackend(), token: "secret")
        let out = await router.handle(raw("GET", "/api/bandwidth"))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"))
        let json = try jsonBody(out)
        XCTAssertEqual(json["enabled"] as? Bool, true)
        XCTAssertEqual(json["selected"] as? String, "Medium")
        let profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[1]["name"] as? String, "Medium")
        XCTAssertEqual(profiles[1]["downBytesPerSec"] as? Int, 5_000)
        XCTAssertTrue(profiles[1]["upBytesPerSec"] is NSNull, "unlimited must be an explicit null")
    }

    func testGetBandwidthWithoutALimiterIs404() async {
        let backend = UploadBackend()
        backend.bandwidth = nil
        let out = str(await RemoteRouter(backend: backend, token: "secret").handle(raw("GET", "/api/bandwidth")))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 404"))
    }

    func testPostBandwidthAppliesAndAnswersWithTheNewState() async throws {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let body = #"{"enabled":false,"selected":"Low","profiles":[{"name":"Low","downBytesPerSec":null,"upBytesPerSec":42}]}"#
        let out = await router.handle(raw("POST", "/api/bandwidth", type: "application/json", body: Data(body.utf8)))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"), str(out))
        let json = try jsonBody(out)
        XCTAssertEqual(json["enabled"] as? Bool, false)
        XCTAssertEqual(json["selected"] as? String, "Low")
        let low = try XCTUnwrap((json["profiles"] as? [[String: Any]])?.first)
        XCTAssertTrue(low["downBytesPerSec"] is NSNull)
        XCTAssertEqual(low["upBytesPerSec"] as? Int, 42)
    }

    func testPostBandwidthKeepsAnAbsentCapAndAcceptsAnEmptyObject() async throws {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = await router.handle(raw("POST", "/api/bandwidth", type: "application/json",
                                          body: Data(#"{"profiles":[{"name":"Low","upBytesPerSec":7}]}"#.utf8)))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"))
        let caps = try XCTUnwrap(backend.bandwidthUpdates.first?.profiles?.first)
        XCTAssertTrue(caps.downBytesPerSec == nil, "absent must mean unchanged, not unlimited")
        XCTAssertEqual(caps.upBytesPerSec, .some(7))

        let empty = await router.handle(raw("POST", "/api/bandwidth", type: "application/json", body: Data("{}".utf8)))
        XCTAssertTrue(str(empty).hasPrefix("HTTP/1.1 200 OK"))
    }

    func testPostBandwidthRejectsBadInput() async {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        for body in [#"{"selected":"Turbo"}"#,
                     #"{"profiles":[{"name":"Nope","downBytesPerSec":1}]}"#,
                     #"{"profiles":[{"name":"Low","downBytesPerSec":-1}]}"#,
                     #"{"profiles":[{"name":"Low","upBytesPerSec":-5}]}"#,
                     #"{"profiles":[{"name":"Low"},{"name":"Low"}]}"#,
                     #"{"profiles":[{"downBytesPerSec":1}]}"#,
                     #"{"enabled":"yes"}"#,
                     #"{"profiles":[{"name":"Low","downBytesPerSec":1.5}]}"#,
                     "not json"] {
            let out = str(await router.handle(raw("POST", "/api/bandwidth", type: "application/json",
                                                  body: Data(body.utf8))))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(body) → \(out.prefix(40))")
        }
        XCTAssertTrue(backend.bandwidthUpdates.isEmpty, "nothing invalid may reach the backend")
    }

    func testPostBandwidthRefusesAPolicyLockedChangeButNotAnEcho() async {
        let backend = UploadBackend()
        backend.bandwidth?.locked = [.enabled, .selected]
        let router = RemoteRouter(backend: backend, token: "secret")
        for body in [#"{"enabled":false}"#, #"{"selected":"Low"}"#] {
            let out = str(await router.handle(raw("POST", "/api/bandwidth", type: "application/json",
                                                  body: Data(body.utf8))))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), body)
        }
        XCTAssertTrue(backend.bandwidthUpdates.isEmpty)
        // Posting the GET object back unchanged must not trip the lock.
        let echo = str(await router.handle(raw("POST", "/api/bandwidth", type: "application/json",
                                               body: Data(#"{"enabled":true,"selected":"Medium"}"#.utf8))))
        XCTAssertTrue(echo.hasPrefix("HTTP/1.1 200 OK"))
    }

    func testReadOnlyRefusesBandwidthAndUploadsButStillServesGet() async {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, config: .init(token: "secret", readOnly: true))
        let get = str(await router.handle(raw("GET", "/api/bandwidth")))
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 200 OK"))
        let post = str(await router.handle(raw("POST", "/api/bandwidth", type: "application/json",
                                               body: Data(#"{"enabled":false}"#.utf8))))
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 403"))
        let uploaded = str(await router.handle(upload([("file", "a.torrent", torrent("a"))])))
        XCTAssertTrue(uploaded.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(backend.bandwidthUpdates.isEmpty)
        XCTAssertTrue(backend.torrents.isEmpty)
    }

    func testUnauthenticatedRequestsAreRefused() async {
        let router = RemoteRouter(backend: UploadBackend(), token: "secret")
        let get = str(await router.handle(RemoteRequest(raw: Data("GET /api/bandwidth HTTP/1.1\r\n\r\n".utf8))))
        XCTAssertTrue(get.hasPrefix("HTTP/1.1 401"))
    }

    func testBandwidthStateReflectsPolicyLocks() {
        var settings = AppSettings()
        settings.profiles = [.low, .medium]
        settings.selectedProfileName = TrafficProfile.low.name
        let open = RemoteBandwidthState(settings: settings, policy: ManagedPolicy())
        XCTAssertEqual(open.locked, [])
        XCTAssertEqual(open.selected, TrafficProfile.low.name)

        let locked = RemoteBandwidthState(settings: settings, policy: ManagedPolicy(forced: [
            .speedLimitEnabled: .bool(true), .selectedProfileName: .string("Low")]))
        XCTAssertEqual(Set(locked.locked), [.enabled, .selected])

        // A forced ceiling forces the limiter on, so `enabled` is not the user's to turn off.
        let ceiling = RemoteBandwidthState(settings: settings, policy: ManagedPolicy(forced: [
            .maxDownloadBytesPerSec: .int(1_000)]))
        XCTAssertEqual(ceiling.locked, [.enabled])
    }

    func testManagerAppliesBandwidthToItsSettings() async throws {
        var settings = AppSettings()
        settings.speedLimitEnabled = true
        let manager = DownloadManager(httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
                                      settings: settings)
        let current = await manager.bandwidthState()
        let before = try XCTUnwrap(current)
        let target = try XCTUnwrap(before.profiles.first { $0.name != before.selected })
        let update = RemoteBandwidthUpdate(
            enabled: false, selected: target.name,
            profiles: [.init(name: target.name, downBytesPerSec: .some(123_456), upBytesPerSec: .some(nil))])
        XCTAssertNil(update.problem(against: before))
        let result = await manager.updateBandwidth(update)
        let after = try XCTUnwrap(result)
        XCTAssertFalse(after.enabled)
        XCTAssertEqual(after.selected, target.name)
        let applied = try XCTUnwrap(after.profiles.first { $0.name == target.name })
        XCTAssertEqual(applied.downBytesPerSec, 123_456)
        XCTAssertNil(applied.upBytesPerSec)
        let stored = await manager.settings
        XCTAssertFalse(stored.speedLimitEnabled)
        XCTAssertEqual(stored.selectedProfileName, target.name)
    }

    // MARK: - /api/add-torrent

    private let boundary = "----GoelTestBoundary7MA4YWxk"

    private func torrent(_ tag: String) -> Data { Data("d8:announce4:http4:info\(tag)e".utf8) }

    private func upload(_ files: [(String, String?, Data)], fields: [String: String] = [:],
                        type: String? = nil) -> RemoteRequest {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        for (name, filename, data) in files {
            let fn = filename.map { "; filename=\"\($0)\"" } ?? ""
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\(fn)\r\nContent-Type: application/x-bittorrent\r\n\r\n".utf8)
            body += data
            body += Data("\r\n".utf8)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        return raw("POST", RemoteTorrentUpload.path,
                   type: type ?? "multipart/form-data; boundary=\(boundary)", body: body)
    }

    func testUploadQueuesEveryTorrentWithTheFolderAndPausedFlag() async throws {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = await router.handle(upload(
            [("file", "Ubuntu 24.04.torrent", torrent("1")), ("file", "C:\\Users\\me\\debian.torrent", torrent("2"))],
            fields: ["dir": " /srv/media ", "paused": "1"]))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"), str(out))
        let json = try jsonBody(out)
        XCTAssertEqual(json["added"] as? Int, 2)
        XCTAssertEqual((json["ids"] as? [String])?.count, 2)
        XCTAssertEqual((json["errors"] as? [Any])?.count, 0)
        XCTAssertEqual(backend.torrents.map(\.name), ["Ubuntu 24.04", "debian"])
        XCTAssertEqual(backend.torrents.map(\.dir), ["/srv/media", "/srv/media"])
        XCTAssertEqual(backend.torrents.map(\.data), [torrent("1"), torrent("2")])
        XCTAssertTrue(backend.torrents.allSatisfy(\.paused))
    }

    /// The Add dialog's Network choice used to reach `/api/add` only; a .torrent silently ran on `auto`.
    func testUploadCarriesTheNetworkChoiceAndRefusesAMalformedOne() async throws {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let out = await router.handle(upload([("file", "a.torrent", torrent("a"))],
                                             fields: ["network": "aggregate"]))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"), str(out))
        XCTAssertEqual(backend.networks, [NetworkSelection(spec: "aggregate")])

        let none = await router.handle(upload([("file", "b.torrent", torrent("b"))]))
        XCTAssertTrue(str(none).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(backend.networks.last, .some(nil))

        let bad = await router.handle(upload([("file", "c.torrent", torrent("c"))],
                                             fields: ["network": "teleport:everywhere"]))
        XCTAssertTrue(str(bad).hasPrefix("HTTP/1.1 400"), str(bad))
        XCTAssertEqual(backend.torrents.count, 2)
    }

    func testUploadReportsPerFileFailuresAlongsideSuccesses() async throws {
        let backend = UploadBackend()
        backend.failNames = ["engine-fails"]
        let router = RemoteRouter(backend: backend, token: "secret")
        let tooBig = Data("d".utf8) + Data(count: RemoteTorrentUpload.maxFileBytes) + Data("e".utf8)
        let out = await router.handle(upload([
            ("file", "good.torrent", torrent("g")),
            ("file", "page.torrent", Data("<html>nope</html>".utf8)),
            ("file", "empty.torrent", Data()),
            ("file", "huge.torrent", tooBig),
            ("file", "engine-fails.torrent", torrent("x")),
        ]))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 200 OK"))
        let json = try jsonBody(out)
        XCTAssertEqual(json["added"] as? Int, 1)
        XCTAssertEqual(json["refused"] as? Int, 4)
        let errors = try XCTUnwrap(json["errors"] as? [[String: String]])
        XCTAssertEqual(errors.map { $0["file"] }, ["page.torrent", "empty.torrent", "huge.torrent", "engine-fails.torrent"])
        XCTAssertEqual(errors.last?["error"], "engine said no")
        XCTAssertEqual(backend.torrents.map(\.name), ["good"])
    }

    func testUploadWhereEveryFileFailsIs400WithTheSameEnvelope() async throws {
        let backend = UploadBackend()
        let out = await RemoteRouter(backend: backend, token: "secret").handle(
            upload([("file", "x.torrent", Data("PK\u{3}\u{4}".utf8))]))
        XCTAssertTrue(str(out).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(str(out).contains("Content-Type: application/json"))
        let json = try jsonBody(out)
        XCTAssertEqual(json["added"] as? Int, 0)
        XCTAssertEqual((json["errors"] as? [[String: String]])?.first?["file"], "x.torrent")
    }

    func testUploadRejectsNonMultipartMalformedEmptyAndTooMany() async {
        let backend = UploadBackend()
        let router = RemoteRouter(backend: backend, token: "secret")
        let cases: [(String, RemoteRequest)] = [
            ("json", raw("POST", RemoteTorrentUpload.path, type: "application/json", body: Data("{}".utf8))),
            ("no boundary", upload([("file", "a.torrent", torrent("a"))], type: "multipart/form-data")),
            ("wrong boundary", upload([("file", "a.torrent", torrent("a"))], type: "multipart/form-data; boundary=zzz")),
            ("no file part", upload([("other", "a.torrent", torrent("a"))])),
            ("too many", upload((0...RemoteTorrentUpload.maxFiles).map { ("file", "\($0).torrent", torrent("\($0)")) })),
        ]
        for (label, request) in cases {
            let out = str(await router.handle(request))
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 400"), "\(label): \(out.prefix(60))")
        }
        XCTAssertTrue(backend.torrents.isEmpty)
    }

    func testUploadOverTheTotalCapIs413() async {
        let backend = UploadBackend()
        let chunk = Data("d".utf8) + Data(count: 9 * 1024 * 1024) + Data("e".utf8)
        let out = str(await RemoteRouter(backend: backend, token: "secret").handle(
            upload([("file", "1.torrent", chunk), ("file", "2.torrent", chunk), ("file", "3.torrent", chunk)])))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 413"), String(out.prefix(40)))
        XCTAssertTrue(backend.torrents.isEmpty)
    }

    func testUploadRefusesAnUnusableFolder() async {
        let backend = UploadBackend()
        backend.allowedFolders = []
        let out = str(await RemoteRouter(backend: backend, token: "secret").handle(
            upload([("file", "a.torrent", torrent("a"))], fields: ["dir": "/etc"])))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(backend.torrents.isEmpty)
    }

    func testUploadRefusesAForeignOrigin() async {
        let backend = UploadBackend()
        var request = upload([("file", "a.torrent", torrent("a"))])
        request.headers["origin"] = "https://evil.example"
        request.headers["host"] = "nas:9800"
        let out = str(await RemoteRouter(backend: backend, token: "secret").handle(request))
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(backend.torrents.isEmpty)
    }

    func testDefaultBackendCannotAddTorrents() async throws {
        final class Bare: RemoteBackend, @unchecked Sendable {
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
        let out = await RemoteRouter(backend: Bare(), token: "secret").handle(upload([("file", "a.torrent", torrent("a"))]))
        let json = try jsonBody(out)
        XCTAssertEqual((json["errors"] as? [[String: String]])?.first?["error"],
                       RemoteTorrentUpload.Failure.unsupported.message)
        let bw = str(await RemoteRouter(backend: Bare(), token: "secret").handle(raw("GET", "/api/bandwidth")))
        XCTAssertTrue(bw.hasPrefix("HTTP/1.1 404"))
    }

    // MARK: - Helpers and limits

    func testDisplayNameStripsPathsExtensionsAndHostileScalars() {
        XCTAssertEqual(RemoteTorrentUpload.displayName("../../etc/passwd.torrent"), "passwd")
        XCTAssertEqual(RemoteTorrentUpload.displayName("C:\\x\\y\\Film.TORRENT"), "Film")
        XCTAssertEqual(RemoteTorrentUpload.displayName(".hidden.torrent"), "torrent")
        XCTAssertEqual(RemoteTorrentUpload.displayName(nil), "torrent")
        XCTAssertEqual(RemoteTorrentUpload.displayName("inv\u{202E}oice.torrent"), "invoice")
        XCTAssertLessThanOrEqual(RemoteTorrentUpload.displayName(String(repeating: "a", count: 500)).count, 120)
    }

    func testBencodeSniff() {
        XCTAssertTrue(RemoteTorrentUpload.looksBencoded(Data("de".utf8)))
        XCTAssertFalse(RemoteTorrentUpload.looksBencoded(Data("d".utf8)))
        XCTAssertFalse(RemoteTorrentUpload.looksBencoded(Data("l4:spame".utf8)))
        XCTAssertFalse(RemoteTorrentUpload.looksBencoded(Data("d4:spam".utf8)))
        XCTAssertTrue(RemoteTorrentUpload.looksBencoded(Data("xd4:spame".utf8).dropFirst()))
    }

    func testSpoolWritesOnlyUUIDNamedFilesInsideItsFolderAndDiscardsThem() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goel-spool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try RemoteTorrentSpool.write(Data("de".utf8), into: dir)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertNotNil(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: file), Data("de".utf8))

        // Anything outside the spool — even a .torrent — is never deleted.
        let outside = dir.deletingLastPathComponent().appendingPathComponent("keep-\(UUID().uuidString).torrent")
        try Data("de".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        RemoteTorrentSpool.discard(.torrentFile(outside), directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        RemoteTorrentSpool.discard(.torrentFile(dir.appendingPathComponent("../\(outside.lastPathComponent)")),
                                   directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        RemoteTorrentSpool.discard(.torrentFile(file), directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOnlyAMultipartTorrentUploadGetsTheLargerBufferCeiling() {
        func header(_ s: String) -> Data { Data(s.utf8) }
        let upload = header("POST /api/add-torrent HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\n\r\n")
        XCTAssertEqual(RemoteRequest.maxRequestBytes(header: upload), RemoteTorrentUpload.maxRequestBytes)
        let withQuery = header("POST /api/add-torrent?x=1 HTTP/1.1\r\ncontent-type:Multipart/Form-Data;boundary=x\r\n\r\n")
        XCTAssertEqual(RemoteRequest.maxRequestBytes(header: withQuery), RemoteTorrentUpload.maxRequestBytes)
        for other in ["POST /api/add HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\n\r\n",
                      "GET /api/add-torrent HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\n\r\n",
                      "POST /api/add-torrent HTTP/1.1\r\nContent-Type: application/json\r\n\r\n",
                      "POST /api/add-torrent HTTP/1.1\r\nX-Note: content-type: multipart/form-data\r\n\r\n",
                      "POST /api/add-torrent/../x HTTP/1.1\r\nContent-Type: multipart/form-data\r\n\r\n"] {
            XCTAssertEqual(RemoteRequest.maxRequestBytes(header: header(other)),
                           RemoteRequest.generalMaxRequestBytes, other)
        }
    }

    func testBufferLimitRefusesAnOversizedDeclaredLengthUpFront() {
        let small = Data("POST /api/add HTTP/1.1\r\nContent-Length: \(3 * 1024 * 1024)\r\n\r\n".utf8)
        XCTAssertTrue(RemoteRequest.exceedsLimit(small))
        let upload = Data("POST /api/add-torrent HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\nContent-Length: \(20 * 1024 * 1024)\r\n\r\n".utf8)
        XCTAssertFalse(RemoteRequest.exceedsLimit(upload))
        let huge = Data("POST /api/add-torrent HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\nContent-Length: \(64 * 1024 * 1024)\r\n\r\n".utf8)
        XCTAssertTrue(RemoteRequest.exceedsLimit(huge))
        XCTAssertFalse(RemoteRequest.exceedsLimit(Data("GET / HTTP/1.1\r\n".utf8)))
    }

    func testUploadSlotsCapConcurrentLargeBodies() {
        let slots = RemoteUploadSlots(limit: 2)
        let a = NSObject(), b = NSObject(), c = NSObject()
        XCTAssertTrue(slots.tryAcquire(ObjectIdentifier(a)))
        XCTAssertTrue(slots.tryAcquire(ObjectIdentifier(a)), "re-acquire by the same holder is idempotent")
        XCTAssertTrue(slots.tryAcquire(ObjectIdentifier(b)))
        XCTAssertFalse(slots.tryAcquire(ObjectIdentifier(c)))
        slots.release(ObjectIdentifier(a))
        slots.release(ObjectIdentifier(a))
        XCTAssertEqual(slots.inUse, 1)
        XCTAssertTrue(slots.tryAcquire(ObjectIdentifier(c)))
    }

    // MARK: - Through the real server

    #if !os(Linux)
    /// The 2 MB general ceiling must not truncate an upload, and must still drop anything else that large.
    func testServerAcceptsAMultiMegabyteUploadButStillCapsOtherRoutes() async throws {
        let backend = UploadBackend()
        let server = RemoteControlServer(manager: backend)
        let port = LoopbackPort.reserve()
        await server.start(port: port, allowLAN: false,
                           config: RemoteRouter.Config(token: "secret", requireAuth: true, username: "admin"),
                           passwordHash: PortalTestCredentials.hash, sessionMinutes: 120)
        guard await server.boundState() != nil else {
            throw XCTSkip("could not bind a loopback port in this environment")
        }
        defer { Task { await server.stop() } }

        let big = Data("d".utf8) + Data(repeating: 0x61, count: 3 * 1024 * 1024) + Data("e".utf8)
        let request = upload([("file", "big.torrent", big)])
        var wire = "POST \(RemoteTorrentUpload.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        wire += "Authorization: Bearer secret\r\n"
        wire += "Content-Type: multipart/form-data; boundary=\(boundary)\r\n"
        wire += "Content-Length: \(request.body.count)\r\nConnection: close\r\n\r\n"
        var reply: String?
        for _ in 0..<20 {
            reply = await exchange(Data(wire.utf8) + request.body, port: port)
            if reply != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let answer = try XCTUnwrap(reply)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 OK"), String(answer.prefix(80)))
        XCTAssertEqual(backend.torrents.first?.data, big)

        var json = "POST /api/add HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\n"
        json += "Content-Type: application/json\r\nContent-Length: \(request.body.count)\r\n\r\n"
        let dropped = await exchange(Data(json.utf8) + request.body, port: port)
        XCTAssertNil(dropped, "a 3 MB body on any other route must still be dropped")
    }

    private func exchange(_ payload: Data, port: UInt16) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(host: .ipv4(.loopback),
                                    port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "upload-probe.\(port)")
            var finished = false
            func finish(_ value: String?) {
                queue.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            finish(data.flatMap { $0.isEmpty ? nil : String(decoding: $0, as: UTF8.self) })
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 8) { finish(nil) }
            conn.start(queue: queue)
        }
    }
    #endif
}
