import XCTest
@testable import GoelCore

/// `/stream?file=`, `?zip=1` and `?history=` hand files off this host, so what they may reach and the
/// bytes they produce are both pinned here.
final class RemoteZipStreamTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/Show/Season 1", withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: root + "/Show/a.txt"))
        try Data((0..<700_000).map { UInt8($0 % 251) })
            .write(to: URL(fileURLWithPath: root + "/Show/Season 1/b.bin"))
        try Data().write(to: URL(fileURLWithPath: root + "/Show/empty.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func torrent(_ files: [TransferFile], status: DownloadStatus = .downloading) -> DownloadTask {
        DownloadTask(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))"),
                     name: "Show", saveDirectory: root, status: status, files: files)
    }

    private func drain(_ zip: inout RemoteZipStream) -> Data {
        var out = Data()
        while let chunk = zip.next() { out.append(chunk) }
        return out
    }

    func testCRC32MatchesTheReferenceValue() {
        XCTAssertEqual(RemoteZipStream.crc32(Data("hello".utf8)), 0x3610_A686)
        let split = RemoteZipStream.crc32(Data("lo".utf8), seed: RemoteZipStream.crc32(Data("hel".utf8)))
        XCTAssertEqual(split, 0x3610_A686)
    }

    func testArchiveLengthMatchesThePromisedContentLengthAndUnzips() throws {
        let task = torrent([
            TransferFile(id: 0, path: "Show/a.txt", length: 5, bytesCompleted: 5),
            TransferFile(id: 1, path: "Show/Season 1/b.bin", length: 700_000, bytesCompleted: 700_000),
            TransferFile(id: 2, path: "Show/empty.txt", length: 0, bytesCompleted: 0),
        ])
        let entries = RemoteStreamService.zipEntries(for: task)
        XCTAssertEqual(entries.map(\.name), ["Show/a.txt", "Show/Season 1/b.bin", "Show/empty.txt"])
        var zip = RemoteZipStream(entries: entries)
        let bytes = drain(&zip)
        XCTAssertEqual(Int64(bytes.count), zip.contentLength)
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))

        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return }
        let archive = root + "/out.zip"
        try bytes.write(to: URL(fileURLWithPath: archive))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: unzip)
        process.arguments = ["-tq", archive]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip -t rejected the archive")
    }

    func testUnfinishedSkippedAndEscapingFilesAreNeitherZippedNorServed() {
        let task = torrent([
            TransferFile(id: 0, path: "Show/a.txt", length: 5, bytesCompleted: 5),
            TransferFile(id: 1, path: "Show/Season 1/b.bin", length: 700_000, bytesCompleted: 10),
            TransferFile(id: 2, path: "Show/empty.txt", length: 0, priority: .skip),
            TransferFile(id: 3, path: "../../etc/passwd", length: 1, bytesCompleted: 1),
        ])
        XCTAssertEqual(RemoteStreamService.zipEntries(for: task).map(\.name), ["Show/a.txt"])
        XCTAssertNotNil(RemoteStreamService.filePlan(for: task, fileID: 0))
        XCTAssertNil(RemoteStreamService.filePlan(for: task, fileID: 1), "not finished")
        XCTAssertNil(RemoteStreamService.filePlan(for: task, fileID: 2), "skipped")
        XCTAssertNil(RemoteStreamService.filePlan(for: task, fileID: 3), "outside the save folder")
        XCTAssertNil(RemoteStreamService.filePlan(for: task, fileID: 99))
    }

    func testZip64RecordsAppearOnlyWhenASizeNeedsThem() {
        let small = RemoteZipStream(entries: [.init(name: "a", path: "/x", size: 10, modified: Date())])
        XCTAssertEqual(small.contentLength, (30 + 1 + 10 + 16) + (46 + 1) + 22)

        let size: Int64 = 5_000_000_000
        let big = RemoteZipStream(entries: [.init(name: "big", path: "/x", size: size, modified: Date())])
        // Local extra, descriptor, central extra and the ZIP64 end records all switch on.
        XCTAssertEqual(big.contentLength, (30 + 3 + 20 + size + 24) + (46 + 3 + 28) + (56 + 20) + 22)
    }

    func testContentDispositionCannotBreakTheHeader() {
        let header = RemoteStreamService.contentDisposition("a\"b\r\nSet-Cookie: x.zip")
        XCTAssertFalse(header.contains("\r"))
        XCTAssertFalse(header.contains("\n"))
        XCTAssertTrue(header.hasPrefix("attachment; filename=\"a_b__Set-Cookie: x.zip\""), header)
        XCTAssertTrue(RemoteStreamService.contentDisposition("Café.mkv").contains("filename*=UTF-8''Caf%C3%A9.mkv"))
        XCTAssertTrue(RemoteStreamService.contentDisposition("日本 (1).mkv")
            .hasSuffix("filename*=UTF-8''%E6%97%A5%E6%9C%AC%20%281%29.mkv"))
    }

    func testArchiveEntryNamesLoseBackslashesControlsAndEmptyParts() {
        XCTAssertEqual(RemoteStreamService.archiveEntryName(["Show", "a\\b", "", ".", "c\u{7}d.txt"]),
                       "Show/a_b/c_d.txt")
        XCTAssertNil(RemoteStreamService.archiveEntryName(["Show", "..", "x"]))
        XCTAssertNil(RemoteStreamService.archiveEntryName(["", "."]))
    }

    func testSlicedCRCMatchesTheBytewiseOneAtEveryLength() {
        func reference(_ data: Data) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for byte in data {
                c ^= UInt32(byte)
                for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        let bytes = Data((0..<100_003).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        for length in [0, 1, 7, 8, 9, 15, 16, 17, 63, 100_003] {
            XCTAssertEqual(RemoteZipStream.crc32(bytes.prefix(length)), reference(bytes.prefix(length)),
                           "length \(length)")
        }
        // Unaligned start, and chaining across chunk boundaries.
        let tail = bytes.dropFirst(3)
        XCTAssertEqual(RemoteZipStream.crc32(tail.dropFirst(5), seed: RemoteZipStream.crc32(tail.prefix(5))),
                       reference(tail))
    }

    func testResolveRoutesFileZipAndHistoryRequests() async throws {
        let task = torrent([
            TransferFile(id: 0, path: "Show/a.txt", length: 5, bytesCompleted: 5),
            TransferFile(id: 1, path: "Show/Season 1/b.bin", length: 700_000, bytesCompleted: 700_000),
        ])
        let history = HistoryEntry(id: UUID(), name: "Show", locator: "magnet:?", kind: .torrent,
                                   totalBytes: nil, savePath: root + "/Show", completedAt: Date())
        let backend = FakeRemoteBackend(tasks: [task])
        backend.historyEntries = [history]
        let id = task.id.uuidString

        guard case .file(let plan, let name) = await RemoteStreamService.resolve(
            query: ["id": id, "file": "1"], backend: backend) else { return XCTFail("file") }
        XCTAssertEqual(plan.totalBytes, 700_000)
        XCTAssertEqual(name, "b.bin")

        guard case .zip(let entries, let archive) = await RemoteStreamService.resolve(
            query: ["id": id, "zip": "1"], backend: backend) else { return XCTFail("zip") }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(archive, "Show.zip")

        guard case .zip(let folder, _) = await RemoteStreamService.resolve(
            query: ["history": history.id.uuidString], backend: backend) else { return XCTFail("history") }
        XCTAssertEqual(Set(folder.map(\.name)), ["Show/a.txt", "Show/Season 1/b.bin", "Show/empty.txt"])

        guard case .refused(let status, _) = await RemoteStreamService.resolve(
            query: ["id": id], backend: backend) else { return XCTFail("unfinished torrent streams") }
        XCTAssertTrue(status.hasPrefix("409"))

        guard case .refused(let missing, _) = await RemoteStreamService.resolve(
            query: ["history": UUID().uuidString], backend: backend) else { return XCTFail("unknown") }
        XCTAssertTrue(missing.hasPrefix("404"))
    }

    func testFolderWalkSkipsSymlinksThatLeaveTheFolder() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/Show/escape", withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: root + "/Show/hosts",
                                                   withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: root + "/Show/season-link",
                                                   withDestinationPath: root + "/Show/Season 1")
        guard case .entries(let entries) = RemoteStreamService.folderEntries(root + "/Show") else {
            return XCTFail("walk")
        }
        let names = entries.map(\.name)
        XCTAssertFalse(names.contains { $0.contains("escape") || $0.hasSuffix("hosts") }, "\(names)")
        XCTAssertFalse(names.contains { $0.contains("season-link") }, "a linked folder is not descended")
    }

    func testFolderWalkRefusesRatherThanTruncates() throws {
        try FileManager.default.createDirectory(atPath: root + "/Show/.git", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/Show/.git/config"))
        guard case .entries(let all) = RemoteStreamService.folderEntries(root + "/Show") else {
            return XCTFail("walk")
        }
        XCTAssertFalse(all.contains { $0.name.contains(".git") }, "hidden items are skipped")
        XCTAssertEqual(RemoteStreamService.folderEntries(root + "/Show", fileLimit: 2), .tooLarge(limit: 2))
        // Folders count too: a tree of empty directories is still bounded.
        XCTAssertEqual(RemoteStreamService.folderEntries(root + "/Show", visitLimit: 2), .tooLarge(limit: 2))
    }

    private func historyBackend(_ savePath: String) -> (FakeRemoteBackend, String) {
        let entry = HistoryEntry(id: UUID(), name: "x", locator: "magnet:?", kind: .torrent,
                                 totalBytes: nil, savePath: savePath, completedAt: Date())
        let backend = FakeRemoteBackend()
        backend.historyEntries = [entry]
        return (backend, entry.id.uuidString)
    }

    func testHistoryIsServedOnlyInsideAnAllowedFolderAndNeverAsARoot() async throws {
        let allowed = RemoteStreamService.normalized(root + "/Show")
        func status(_ savePath: String, roots: [String] = []) async -> String {
            let (backend, id) = historyBackend(savePath)
            backend.allowedFolder = { RemoteStreamService.normalized($0).hasPrefix(allowed) }
            backend.downloadRoots = roots
            switch await RemoteStreamService.resolve(query: ["history": id], backend: backend) {
            case .refused(let status, _): return status
            case .file: return "file"
            case .zip: return "zip"
            }
        }
        let good = await status(root + "/Show/Season 1")
        XCTAssertEqual(good, "zip")
        let file = await status(root + "/Show/a.txt")
        XCTAssertEqual(file, "file")
        let outside = await status("/etc/hosts")
        XCTAssertTrue(outside.hasPrefix("403"), outside)
        let traversal = await status(root + "/Show/Season 1/../../../../../etc/hosts")
        XCTAssertTrue(traversal.hasPrefix("403"), traversal)
        let wholeRoot = await status(root + "/Show/Season 1", roots: [root + "/Show/Season 1/"])
        XCTAssertTrue(wholeRoot.hasPrefix("403"), wholeRoot)
        try Data("s".utf8).write(to: URL(fileURLWithPath: root + "/Show/.secret"))
        let hidden = await status(root + "/Show/.secret")
        XCTAssertTrue(hidden.hasPrefix("403"), hidden)
        // A link planted where the download was is judged by where it leads.
        try FileManager.default.createSymbolicLink(atPath: root + "/Show/planted", withDestinationPath: "/etc/hosts")
        let planted = await status(root + "/Show/planted")
        XCTAssertTrue(planted.hasPrefix("403"), planted)
    }

    func testHistoryLookupStaysWithinWhatThePortalLists() async {
        let backend = FakeRemoteBackend()
        backend.historyEntries = (0..<(RemoteRouter.historyLimit + 1)).map { i in
            HistoryEntry(id: UUID(), name: "\(i)", locator: "magnet:?", kind: .torrent,
                         totalBytes: nil, savePath: root, completedAt: Date())
        }
        let listed = await backend.historyEntry(backend.historyEntries[0].id)
        XCTAssertNotNil(listed)
        let beyond = await backend.historyEntry(backend.historyEntries[RemoteRouter.historyLimit].id)
        XCTAssertNil(beyond, "not something the portal could have shown")
    }

    func testOpenChecksTheDescriptorNotTheName() throws {
        let show = root + "/Show"
        XCTAssertNotNil(RemoteServedFile.open(show + "/a.txt", within: show, minimumSize: 5))
        XCTAssertNil(RemoteServedFile.open(show + "/a.txt", within: show, minimumSize: 6), "shrank since planning")
        XCTAssertNil(RemoteServedFile.open(show + "/Season 1", within: show, minimumSize: 0), "a folder")
        XCTAssertNil(RemoteServedFile.open(show + "/a.txt", within: show + "/Season 1", minimumSize: 0),
                     "outside its root")
        try FileManager.default.createSymbolicLink(atPath: show + "/swapped", withDestinationPath: show + "/a.txt")
        XCTAssertNil(RemoteServedFile.open(show + "/swapped", within: show, minimumSize: 0), "final symlink")
        try FileManager.default.createSymbolicLink(atPath: show + "/dirlink", withDestinationPath: "/etc")
        XCTAssertNil(RemoteServedFile.open(show + "/dirlink/hosts", within: show, minimumSize: 0),
                     "a link earlier in the path is caught by the real path")
    }

    func testOnlyArchiveRequestsTakeAnArchiveSlot() {
        XCTAssertTrue(RemoteStreamService.mayBuildArchive(["id": "x", "zip": "1"]))
        XCTAssertTrue(RemoteStreamService.mayBuildArchive(["history": "x"]))
        XCTAssertFalse(RemoteStreamService.mayBuildArchive(["id": "x", "file": "1"]))
        XCTAssertFalse(RemoteStreamService.mayBuildArchive(["id": "x"]))
    }
}

/// The portal words its Settings page by platform: a Linux daemon has no desktop app to point at.
final class RemotePortalBootTests: XCTestCase {
    func testBootJSONNamesTheHostPlatformAndName() throws {
        let page = RemoteRouter.page(config: .init(token: "t"))
        let start = try XCTUnwrap(page.range(of: #"<script id="goel-boot" type="application/json">"#))
        let end = try XCTUnwrap(page.range(of: "</script>", range: start.upperBound..<page.endIndex))
        let boot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(page[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        #if os(Linux)
        XCTAssertEqual(boot["host"] as? String, "linux")
        #else
        XCTAssertEqual(boot["host"] as? String, "mac")
        #endif
        XCTAssertFalse((boot["hostname"] as? String ?? "").hasSuffix(".local"))
    }
}
