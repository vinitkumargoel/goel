import XCTest
import GoelCore
@testable import GoelApp

/// The containers below are the ones users actually download. Matroska is the reason this gate
/// exists: AVFoundation cannot open it, and its way of saying so is to play nothing at all.
final class InAppPlaybackTests: XCTestCase {

    func testRejectsTheContainersAVFoundationCannotDemux() {
        for ext in ["mkv", "webm", "flv", "wmv"] {
            XCTAssertFalse(
                InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie.\(ext)")),
                "\(ext) has no AVFoundation demuxer — offering the built-in player shows a dead frame"
            )
        }
    }

    func testAcceptsTheQuickTimeFamily() {
        for ext in ["mp4", "mov", "m4v", "mp3", "m4a", "wav"] {
            XCTAssertTrue(
                InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie.\(ext)")),
                "\(ext) is playable, so hiding the built-in player would be a regression"
            )
        }
    }

    func testRejectsWhatItCannotIdentify() {
        XCTAssertFalse(InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie")))
        XCTAssertFalse(InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie.sqzzt")))
    }

    /// Case is not normalised anywhere between the download name and here.
    func testIgnoresExtensionCase() {
        XCTAssertTrue(InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie.MP4")))
        XCTAssertFalse(InAppPlayback.canPlay(URL(fileURLWithPath: "/tmp/movie.MKV")))
    }
}
