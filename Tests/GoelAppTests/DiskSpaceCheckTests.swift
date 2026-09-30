import XCTest
import GoelCore
@testable import GoelApp

final class DiskSpaceCheckTests: XCTestCase {

    func testSufficientWhenNeededFitsExactly() {
        let verdict = DiskSpaceCheck.verdict(needed: 100, available: 100)
        XCTAssertEqual(verdict?.isSufficient, true)
    }

    func testInsufficientWhenNeededExceedsFree() {
        let verdict = DiskSpaceCheck.verdict(needed: 48_000_000_000, available: 12_000_000_000)
        XCTAssertEqual(verdict?.isSufficient, false)
    }

    func testNoVerdictWithoutAKnownSizeOrFreeSpace() {
        XCTAssertNil(DiskSpaceCheck.verdict(needed: nil, available: 100))
        XCTAssertNil(DiskSpaceCheck.verdict(needed: 0, available: 100))
        XCTAssertNil(DiskSpaceCheck.verdict(needed: 100, available: nil))
    }

    func testMessageNamesBothSizes() {
        let verdict = DiskSpaceCheck.Verdict(needed: 2_000_000, available: 5_000_000)
        let message = DiskSpaceCheck.message(for: verdict)
        XCTAssertEqual(message, "Needs \(Int64(2_000_000).byteString) · \(Int64(5_000_000).byteString) free")
    }

    func testSpokenMessageSaysWhenThereIsNotEnoughSpace() {
        let low = DiskSpaceCheck.Verdict(needed: 10_000, available: 10)
        XCTAssertTrue(DiskSpaceCheck.spokenMessage(for: low).hasPrefix("Not enough space."))
        let fine = DiskSpaceCheck.Verdict(needed: 10, available: 10_000)
        XCTAssertFalse(DiskSpaceCheck.spokenMessage(for: fine).contains("Not enough"))
    }

    func testCapacityForAnExistingFolderIsPositive() {
        let free = DiskSpaceCheck.availableCapacity(forFolder: NSTemporaryDirectory())
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
    }

    /// Downloads create their folder, so a not-yet-existing path asks its nearest existing parent.
    func testCapacityForAMissingFolderFallsBackToItsParent() {
        let missing = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("goel-missing-\(UUID().uuidString)/deeper")
        XCTAssertNotNil(DiskSpaceCheck.availableCapacity(forFolder: missing))
    }

    func testAutomaticResolvesToTheSubfolderTheDownloadWillUse() {
        var settings = AppSettings()
        settings.defaultSaveDirectory = "/Volumes/Data/Downloads"
        settings.defaultFolderRule = "automatic"
        let video = DownloadSource.url(URL(string: "https://e.test/movie.mkv")!)
        XCTAssertEqual(DiskSpaceCheck.automaticFolder(for: video, suggestedName: "movie.mkv", settings: settings),
                       "/Volumes/Data/Downloads/Video")
        settings.defaultFolderRule = "bySource"
        XCTAssertEqual(DiskSpaceCheck.automaticFolder(for: video, suggestedName: "movie.mkv", settings: settings),
                       "/Volumes/Data/Downloads/HTTP Downloads")
        settings.defaultFolderRule = "none"
        XCTAssertEqual(DiskSpaceCheck.automaticFolder(for: video, suggestedName: "movie.mkv", settings: settings),
                       "/Volumes/Data/Downloads")
    }
}
