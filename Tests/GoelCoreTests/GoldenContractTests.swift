import XCTest
import Foundation
import GoelContracts
@testable import GoelFacade

/// Golden-JSON conformance tests: they pin the *exact wire shape* of the
/// cross-language contract (`GoelContracts`). This is the spec any Android build —
/// a Swift recompile or a Kotlin twin — must reproduce byte-for-byte in structure.
///
/// The riskiest surface is Swift's **synthesized enum Codable** (SE-0295): a case
/// with associated values encodes as `{"case":{…}}` with unlabeled payloads keyed
/// `_0`, `_1`, …; a case with no payload as `{"case":{}}`. A Kotlin reimplementation
/// has to match that layout, so it is frozen here explicitly.
///
/// Comparisons are *structural* (parse both sides, deep-equal) rather than raw
/// bytes, so cosmetic slash-escaping (`\/` vs `/`) — which no JSON parser cares
/// about — doesn't make the suite brittle, while field names, nesting, enum tokens
/// and value types stay strictly pinned.
final class GoldenContractTests: XCTestCase {

    // MARK: Golden helpers

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func parse(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
    }

    /// Assert an encoded value matches a golden JSON string, structurally.
    private func assertGolden<T: Encodable>(_ value: T, _ expected: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            let actual = try encode(value)
            let a = try parse(actual)
            let e = try parse(Data(expected.utf8))
            XCTAssertEqual(a, e,
                "\n  actual:   \(String(decoding: actual, as: UTF8.self))\n  expected: \(expected)",
                file: file, line: line)
        } catch {
            XCTFail("golden encode/parse failed: \(error)", file: file, line: line)
        }
    }

    // MARK: Schema version

    func test_schemaVersion_isPinnedAt1() {
        // Bumping this is a deliberate, breaking act — see SchemaVersion.swift.
        XCTAssertEqual(GoelContract.schemaVersion, 1)
    }

    // MARK: Raw-representable enums (bare tokens)

    func test_downloadKind_wireTokens() {
        assertGolden(DownloadKind.http, "\"http\"")
        assertGolden(DownloadKind.torrent, "\"torrent\"")
        assertGolden(DownloadKind.hls, "\"hls\"")
        assertGolden(DownloadKind.ftp, "\"ftp\"")
        assertGolden(DownloadKind.sftp, "\"sftp\"")
    }

    func test_filePriority_wireTokens() {
        assertGolden(FilePriority.skip, "0")
        assertGolden(FilePriority.low, "1")
        assertGolden(FilePriority.normal, "2")
        assertGolden(FilePriority.high, "3")
    }

    // MARK: Synthesized enums with associated values

    func test_downloadStatus_wireShape() {
        assertGolden(DownloadStatus.queued, #"{"queued":{}}"#)
        assertGolden(DownloadStatus.requestingMetadata, #"{"requestingMetadata":{}}"#)
        assertGolden(DownloadStatus.downloading, #"{"downloading":{}}"#)
        assertGolden(DownloadStatus.verifying, #"{"verifying":{}}"#)
        assertGolden(DownloadStatus.paused, #"{"paused":{}}"#)
        assertGolden(DownloadStatus.seeding, #"{"seeding":{}}"#)
        assertGolden(DownloadStatus.completed, #"{"completed":{}}"#)
        assertGolden(DownloadStatus.failed(.httpStatus(404)),
                     #"{"failed":{"_0":{"httpStatus":{"_0":404}}}}"#)
    }

    func test_downloadError_wireShape() {
        assertGolden(DownloadError.network("boom"), #"{"network":{"_0":"boom"}}"#)
        assertGolden(DownloadError.httpStatus(503), #"{"httpStatus":{"_0":503}}"#)
        assertGolden(DownloadError.diskFull(needed: 10, available: 4),
                     #"{"diskFull":{"available":4,"needed":10}}"#)
        assertGolden(DownloadError.checksumMismatch, #"{"checksumMismatch":{}}"#)
        assertGolden(DownloadError.rangeNotSupported, #"{"rangeNotSupported":{}}"#)
        assertGolden(DownloadError.remoteFileChanged, #"{"remoteFileChanged":{}}"#)
        assertGolden(DownloadError.fileMissing, #"{"fileMissing":{}}"#)
        assertGolden(DownloadError.canceled, #"{"canceled":{}}"#)
        assertGolden(DownloadError.timedOut, #"{"timedOut":{}}"#)
        assertGolden(DownloadError.unknown("x"), #"{"unknown":{"_0":"x"}}"#)
    }

    /// Exhaustiveness tripwire. `DownloadError` carries payloads so it can't be
    /// `CaseIterable`; this `switch` has no `default`, so adding a case stops the
    /// test target compiling until its wire shape is pinned above. A counted
    /// assertion would be a tautology — this actually bites.
    private func everyDownloadErrorCaseIsPinned(_ error: DownloadError) {
        switch error {
        case .network, .httpStatus, .diskFull, .checksumMismatch, .rangeNotSupported,
             .remoteFileChanged, .fileMissing, .canceled, .timedOut, .unknown:
            break
        }
    }

    /// Same tripwire for the status enum.
    private func everyDownloadStatusCaseIsPinned(_ status: DownloadStatus) {
        switch status {
        case .queued, .requestingMetadata, .downloading, .verifying,
             .paused, .seeding, .completed, .failed:
            break
        }
    }

    func test_downloadSource_wireShape() {
        assertGolden(DownloadSource.url(URL(string: "https://example.com/a.zip")!),
                     #"{"url":{"_0":"https://example.com/a.zip"}}"#)
        assertGolden(DownloadSource.magnet("magnet:?xt=urn:btih:abc"),
                     #"{"magnet":{"_0":"magnet:?xt=urn:btih:abc"}}"#)
        assertGolden(DownloadSource.torrentFile(URL(string: "https://example.com/x.torrent")!),
                     #"{"torrentFile":{"_0":"https://example.com/x.torrent"}}"#)
        assertGolden(DownloadSource.hlsStream(URL(string: "https://example.com/s.m3u8")!),
                     #"{"hlsStream":{"_0":"https://example.com/s.m3u8"}}"#)
    }

    // MARK: Date & Data encoding — the two silent cross-language traps

    /// Foundation's DEFAULT date strategy (`.deferredToDate`) is seconds since
    /// **2001-01-01**, not the Unix epoch. This is what `PersistenceStore` writes
    /// to disk and what any plain `JSONEncoder()` produces for a contract type.
    /// A Kotlin twin that reads it as Unix epoch is wrong by 978307200s (~31
    /// years), silently, in every timestamp and every "added" sort. Pinned so the
    /// value can never drift unnoticed — and so the offset is documented, not
    /// discovered.
    func test_domainDate_usesAppleReferenceEpoch_notUnix() throws {
        struct Box: Encodable { var at: Date }
        let unix: TimeInterval = 1_700_000_000
        let data = try encode(Box(at: Date(timeIntervalSince1970: unix)))

        assertGolden(Box(at: Date(timeIntervalSince1970: unix)), #"{"at":721692800}"#)
        // The exact relationship a non-Swift reader must apply.
        let encoded = try parse(data) as! [String: Any]
        XCTAssertEqual(encoded["at"] as! TimeInterval, unix - 978_307_200)
    }

    /// The facade boundary deliberately pins `.secondsSince1970` instead, so a
    /// foreign consumer sees ordinary Unix time. Both epochs are in play in this
    /// codebase (`Wire.TaskRow.addedAt` is also Unix); pinning both keeps the
    /// difference deliberate rather than accidental.
    func test_facadeDate_usesUnixEpoch() throws {
        struct Box: Codable, Equatable { var at: Date }
        let box = Box(at: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try GoelFacade.makeEncoder().encode(box)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"at":1700000000}"#)
        XCTAssertEqual(try GoelFacade.makeDecoder().decode(Box.self, from: data), box)
    }

    /// `Data` (e.g. `DownloadTask.resumeData`) encodes as base64 — same class of
    /// trap as dates if a twin assumes a byte array.
    func test_data_encodesAsBase64() {
        struct Box: Encodable { var blob: Data }
        assertGolden(Box(blob: Data([0xDE, 0xAD, 0xBE, 0xEF])), #"{"blob":"3q2+7w=="}"#)
    }

    // MARK: Wire DTOs (portal / companion-client responses)

    func test_wireFileRow_golden() {
        let row = Wire.FileRow(id: 3, name: "clip.mp4", size: 2048, done: 1024,
                               progress: 0.5, priority: "normal")
        assertGolden(row,
            #"{"done":1024,"id":3,"name":"clip.mp4","priority":"normal","progress":0.5,"size":2048}"#)
    }

    func test_wireConfigRow_golden() {
        let row = Wire.ConfigRow(username: "vinit", readOnly: false, requireAuth: true, theme: "dark")
        assertGolden(row,
            #"{"appName":"Goel°","readOnly":false,"requireAuth":true,"theme":"dark","username":"vinit"}"#)
    }

    func test_wireCountRow_golden() {
        assertGolden(Wire.CountRow(added: 2), #"{"added":2}"#)
    }

    func test_wireHistoryRow_golden() {
        let row = Wire.HistoryRow(id: "abc", name: "ubuntu.iso", kind: "torrent",
                                  totalBytes: 999, savePath: "/dl/ubuntu.iso",
                                  completedAt: 100, source: "magnet:?x")
        assertGolden(row,
            #"{"completedAt":100,"id":"abc","kind":"torrent","name":"ubuntu.iso","savePath":"/dl/ubuntu.iso","source":"magnet:?x","totalBytes":999}"#)
    }

    func test_wireTaskRow_golden() {
        let row = Wire.TaskRow(
            id: "id1", name: "file.bin", status: "Downloading", statusToken: "downloading",
            kind: "http", progress: 0.25, downSpeed: 100, upSpeed: 0,
            totalBytes: 4000, doneBytes: 1000, upBytes: 0, ratio: 0,
            seeds: nil, conns: 4, addedAt: 12.5, etaSeconds: 30, error: nil,
            source: "https://h/file.bin", multiFile: false, fileCount: 1, streamable: true)
        assertGolden(row,
            // `seeds` and `error` are nil and therefore absent — nil optionals are
            // omitted, not encoded as null. That omission is part of the contract.
            #"{"addedAt":12.5,"conns":4,"doneBytes":1000,"downSpeed":100,"etaSeconds":30,"fileCount":1,"id":"id1","kind":"http","multiFile":false,"name":"file.bin","progress":0.25,"ratio":0,"source":"https://h/file.bin","status":"Downloading","statusToken":"downloading","streamable":true,"totalBytes":4000,"upBytes":0,"upSpeed":0}"#)
    }

    // MARK: AddPayload (the one request DTO — Decodable)

    func test_addPayload_decodesFromWire() throws {
        let json = #"{"url":"https://h/f.zip","folder":"/dl","priority":"high","paused":true}"#
        let payload = try JSONDecoder().decode(Wire.AddPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.url, "https://h/f.zip")
        XCTAssertEqual(payload.folder, "/dl")
        XCTAssertEqual(payload.priority, "high")
        XCTAssertEqual(payload.paused, true)
    }

    func test_addPayload_toleratesMissingOptionals() throws {
        let payload = try JSONDecoder().decode(Wire.AddPayload.self,
                                               from: Data(#"{"url":"https://h/f.zip"}"#.utf8))
        XCTAssertEqual(payload.url, "https://h/f.zip")
        XCTAssertNil(payload.folder)
        XCTAssertNil(payload.priority)
        XCTAssertNil(payload.paused)
    }
}
