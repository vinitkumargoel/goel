import XCTest
@testable import GoelApp

final class FileTypeClassificationTests: XCTestCase {

    private func type(_ name: String, torrent: Bool = false) -> FileType {
        FileType.classify(fileName: name, isTorrent: torrent)
    }

    func testAudioImageAndDocumentExtensions() {
        for name in ["song.mp3", "Album.FLAC", "voice.m4a", "take.wav", "track.opus", "book.m4b"] {
            XCTAssertEqual(type(name), .audio, name)
        }
        for name in ["photo.jpg", "shot.JPEG", "icon.png", "scan.tiff", "live.heic", "art.webp"] {
            XCTAssertEqual(type(name), .image, name)
        }
        for name in ["paper.pdf", "notes.txt", "report.docx", "sheet.xlsx", "book.epub", "data.csv"] {
            XCTAssertEqual(type(name), .doc, name)
        }
    }

    func testTheNewCategoriesNeedTheExtensionToEndTheName() {
        XCTAssertEqual(type("a.pngx"), .other)
        XCTAssertEqual(type("readme.txtish"), .other)
    }

    func testOriginalCategoriesKeepTheirOrderAndSubstringMatching() {
        XCTAssertEqual(type("release.iso.zip"), .iso)
        XCTAssertEqual(type("clip.mp4.part"), .video)
        XCTAssertEqual(type("backup.tar.gz"), .archive)
        XCTAssertEqual(type("Installer.pkg"), .app)
    }

    func testUnknownIsOtherExceptForATorrentWhichIsUsuallyVideo() {
        XCTAssertEqual(type("firmware.bin"), .other)
        XCTAssertEqual(type("noextension"), .other)
        XCTAssertEqual(type("Some.Series.S01", torrent: true), .video)
        XCTAssertEqual(type("OST.flac", torrent: true), .audio, "a known extension beats the torrent guess")
    }

    func testEveryTypeHasANameAndGlyph() {
        for type in FileType.allCases {
            XCTAssertFalse(type.accessibilityName.isEmpty)
            XCTAssertFalse(type.symbol.isEmpty)
        }
    }
}
