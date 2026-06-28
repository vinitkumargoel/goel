import XCTest
@testable import GoelCore

final class ModelTests: XCTestCase {

    func testKindDerivedFromSource() {
        XCTAssertEqual(DownloadSource.url(URL(string: "https://x/y.iso")!).kind, .http)
        XCTAssertEqual(DownloadSource.magnet("magnet:?xt=urn:btih:abc").kind, .torrent)
        XCTAssertEqual(DownloadSource.torrentFile(URL(string: "file:///a.torrent")!).kind, .torrent)
    }

    func testFractionCompleted() {
        var task = DownloadTask(
            source: .url(URL(string: "https://x/y.iso")!),
            name: "y.iso",
            saveDirectory: "/tmp",
            totalBytes: 1000,
            bytesDownloaded: 250
        )
        XCTAssertEqual(task.fractionCompleted, 0.25, accuracy: 0.0001)

        task.status = .completed
        XCTAssertEqual(task.fractionCompleted, 1.0, accuracy: 0.0001)
    }

    func testPreMetadataHasNoFraction() {
        let task = DownloadTask(
            source: .magnet("magnet:?xt=urn:btih:abc"),
            name: "Resolving…",
            saveDirectory: "/tmp",
            totalBytes: nil,
            status: .requestingMetadata
        )
        XCTAssertFalse(task.hasMetadata)
        XCTAssertEqual(task.fractionCompleted, 0)
    }

    func testShareRatio() {
        let task = DownloadTask(
            source: .magnet("magnet:?xt=urn:btih:abc"),
            name: "x",
            saveDirectory: "/tmp",
            bytesDownloaded: 1000,
            bytesUploaded: 1500
        )
        XCTAssertEqual(task.shareRatio, 1.5, accuracy: 0.0001)
    }

    func testStatusFlags() {
        XCTAssertTrue(DownloadStatus.seeding.isActive)
        XCTAssertTrue(DownloadStatus.seeding.hasData)
        XCTAssertTrue(DownloadStatus.completed.isTerminal)
        XCTAssertTrue(DownloadStatus.failed(.canceled).isTerminal)
        XCTAssertFalse(DownloadStatus.paused.isActive)
    }

    func testStatusCodableRoundTripWithError() throws {
        let status = DownloadStatus.failed(.diskFull(needed: 100, available: 10))
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(DownloadStatus.self, from: data)
        XCTAssertEqual(status, decoded)
    }

    func testTaskCodableRoundTrip() throws {
        let task = DownloadTask(
            source: .url(URL(string: "https://x/y.iso")!),
            name: "y.iso",
            saveDirectory: "/tmp",
            totalBytes: 5000,
            bytesDownloaded: 1234,
            status: .downloading,
            files: [TransferFile(id: 0, path: "y.iso", length: 5000, bytesCompleted: 1234)]
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: data)
        XCTAssertEqual(task, decoded)
    }

    func testTrafficProfiles() {
        XCTAssertTrue(TrafficProfile.high.isDownloadUnlimited)
        XCTAssertFalse(TrafficProfile.low.isDownloadUnlimited)
        XCTAssertEqual(TrafficProfile.defaults.count, 3)
    }

    func testByteFormatting() {
        XCTAssertEqual(Int64(0).byteString, "—")
        XCTAssertEqual(Int64(512).byteString, "512 B")
        XCTAssertTrue(Int64(5 * 1024 * 1024 * 1024).byteString.hasSuffix("GB"))
    }
}
