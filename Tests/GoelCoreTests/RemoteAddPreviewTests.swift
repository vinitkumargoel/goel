import XCTest
@testable import GoelCore

/// A backend that answers `/api/add-preview`. Everything else is inert.
private final class PreviewBackend: RemoteBackend, RemoteAddPreviewing, @unchecked Sendable {
    var tasks: [DownloadTask] = []
    var free: Int64? = 5_000
    var slow: Set<String> = []
    private(set) var probed: [String] = []
    private(set) var probedFolders: [String?] = []

    func previewAdd(_ source: DownloadSource, saveDirectory: String?) async -> DownloadPreview {
        probed.append(source.locator)
        probedFolders.append(saveDirectory)
        if slow.contains(source.locator) { try? await Task.sleep(for: .seconds(30)) }
        return DownloadPreview(
            source: source, suggestedName: "resolved.iso", totalBytes: 1_234,
            files: [TransferFile(id: 0, path: "a/one.bin", length: 1_000),
                    TransferFile(id: 1, path: "a/two.bin", length: 234)],
            kind: source.kind)
    }

    func freeBytes(forSaveDirectory saveDirectory: String?) async -> Int64? { free }

    func taskSnapshot() async -> [DownloadTask] { tasks }
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
    func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                   startPaused: Bool, network: NetworkSelection?) async -> UUID? { nil }
    func history(limit: Int) async -> [HistoryEntry] { [] }
    func removeHistoryEntry(_ id: UUID) async {}
    func clearHistory() async {}
}

final class RemoteAddPreviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkGuard.hostResolver = PlaceholderHosts.resolver
    }

    override func tearDown() {
        NetworkGuard.useSystemHostResolver()
        super.tearDown()
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            var index: Int
            var status: String
            var name: String?
            var totalBytes: Int64?
            var files: [File]
            var fileCount: Int
            struct File: Decodable { var name: String; var size: Int64 }
        }
        var items: [Item]
        var freeBytes: Int64?
    }

    private func post(_ backend: RemoteBackend, _ body: String) async -> (head: String, reply: Reply?) {
        let router = RemoteRouter(backend: backend, token: "secret")
        let raw = "POST /api/add-preview HTTP/1.1\r\nAuthorization: Bearer secret\r\n" +
            "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let data = await router.handle(RemoteRequest(raw: Data(raw.utf8)))
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return ("", nil) }
        let head = String(decoding: data.prefix(upTo: split.lowerBound), as: UTF8.self)
        return (head, try? JSONDecoder().decode(Reply.self, from: data.suffix(from: split.upperBound)))
    }

    private func body(_ lines: [String], folder: String? = nil) -> String {
        let url = lines.joined(separator: "\n")
        let payload: [String: String] = folder.map { ["url": url, "folder": $0] } ?? ["url": url]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func testEachLineIsClassifiedWithoutEchoingIt() async {
        let backend = PreviewBackend()
        backend.tasks = [DownloadTask(id: UUID(), source: .url(URL(string: "https://e/dup.iso")!), name: "dup.iso",
                                      saveDirectory: "/tmp", status: .downloading)]
        let (head, reply) = await post(backend, body([
            "https://e/new.iso",
            "not a link",
            "https://e/dup.iso",
            "",
            "http://127.0.0.1/secret",
        ]))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        let byIndex = Dictionary(uniqueKeysWithValues: (reply?.items ?? []).map { ($0.index, $0) })
        XCTAssertEqual(byIndex[0]?.status, "ok")
        XCTAssertEqual(byIndex[0]?.name, "resolved.iso")
        XCTAssertEqual(byIndex[0]?.totalBytes, 1_234)
        XCTAssertEqual(byIndex[0]?.files.map(\.name), ["a/one.bin", "a/two.bin"])
        XCTAssertEqual(byIndex[1]?.status, "unsupported")
        XCTAssertEqual(byIndex[2]?.status, "duplicate")
        XCTAssertNil(byIndex[3], "a blank line is not an item")
        XCTAssertEqual(byIndex[4]?.status, "refused")
        XCTAssertEqual(reply?.freeBytes, 5_000)
        // Only the one line that could be queued was probed: never a refused or duplicate target.
        XCTAssertEqual(backend.probed, ["https://e/new.iso"])
    }

    func testInlineCredentialsAreFlaggedNotProbed() async {
        let backend = PreviewBackend()
        let (_, reply) = await post(backend, body(["https://user:pw@e/a.iso"]))
        XCTAssertEqual(reply?.items.first?.status, "credentials")
        XCTAssertTrue(backend.probed.isEmpty)
    }

    func testARefusedFolderIsRefusedBeforeAnyProbe() async {
        final class Strict: RemoteBackend, RemoteAddPreviewing, @unchecked Sendable {
            let inner = PreviewBackend()
            func remoteSaveDirectoryAllowed(_ folder: String) async -> Bool { false }
            func previewAdd(_ s: DownloadSource, saveDirectory: String?) async -> DownloadPreview {
                await inner.previewAdd(s, saveDirectory: saveDirectory)
            }
            func freeBytes(forSaveDirectory: String?) async -> Int64? { nil }
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
            func remoteAdd(source: DownloadSource, saveDirectory: String?, priority: FilePriority,
                           startPaused: Bool, network: NetworkSelection?) async -> UUID? { nil }
            func history(limit: Int) async -> [HistoryEntry] { [] }
            func removeHistoryEntry(_ id: UUID) async {}
            func clearHistory() async {}
        }
        let backend = Strict()
        let (head, _) = await post(backend, body(["https://e/a.iso"], folder: "/etc"))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), head)
        XCTAssertTrue(backend.inner.probed.isEmpty)
    }

    func testABackendWithoutPreviewAnswers404() async {
        let (head, _) = await post(FakeRemoteBackend(), body(["https://e/a.iso"]))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 404"), head)
    }

    func testTheDeadlineGivesUpWaitingOnASlowProbe() async {
        let result = await RemoteAddPreview.withDeadline(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        XCTAssertNil(result)
        let fast = await RemoteAddPreview.withDeadline(.seconds(5)) { 7 }
        XCTAssertEqual(fast, 7)
    }

    func testTheDeadlineCancelsTheWorkItGaveUpOn() async {
        let cancelled = expectation(description: "work cancelled")
        _ = await RemoteAddPreview.withDeadline(.milliseconds(50)) {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelled.fulfill()
            }
            return 1
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testEveryLineCountsAgainstTheCapRefusedOrNot() async {
        let backend = PreviewBackend()
        // Loopback lines are refused by screening, yet each still spends a slot.
        let lines = Array(repeating: "http://127.0.0.1/x", count: RemoteAddPreview.maxLines) + ["https://e/late.iso"]
        let (_, reply) = await post(backend, body(lines))
        let last = reply?.items.first { $0.index == RemoteAddPreview.maxLines }
        XCTAssertEqual(last?.status, "unchecked")
        XCTAssertEqual(reply?.items.filter { $0.status == "refused" }.count, RemoteAddPreview.maxLines)
        XCTAssertTrue(backend.probed.isEmpty)
    }

    func testTooManyPreviewsAtOnceAnswer429() async {
        let gate = RemoteAddPreview.gate
        var held = 0
        while gate.enter() { held += 1 }
        defer { for _ in 0..<held { gate.leave() } }
        XCTAssertEqual(held, RemoteAddPreview.maxInFlight)
        let backend = PreviewBackend()
        let (head, _) = await post(backend, body(["https://e/a.iso"]))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 429"), head)
        XCTAssertTrue(head.contains("Retry-After: 2"), head)
        XCTAssertTrue(backend.probed.isEmpty)
    }

    func testAnEngineNoteIsNotPassedThroughVerbatim() {
        let source = DownloadSource.parse("https://e/a.iso")!
        let preview = DownloadPreview(source: source, suggestedName: "a.iso", totalBytes: nil, kind: .http,
                                      note: "The Internet connection appears to be offline. (NSURLErrorDomain -1009)")
        let item = RemoteRouter.previewItem(index: 0, source: source, preview: preview)
        XCTAssertEqual(item.note, RemoteAddPreview.unresolvedNote)
    }

    func testFreeSpaceLooksAtTheNearestExistingFolder() {
        let missing = NSTemporaryDirectory() + "goel-preview-\(UUID().uuidString)/Video/Deep"
        XCTAssertNotNil(RemoteAddPreview.availableBytes(near: missing))
    }
}
