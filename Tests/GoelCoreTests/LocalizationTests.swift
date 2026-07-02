import XCTest
@testable import GoelCore

/// Proves the L10n pipeline end-to-end: the German table resolves, English is the
/// fallback for a language with no table, and an unknown key returns unchanged.
final class LocalizationTests: XCTestCase {

    func testGermanTranslationsResolve() {
        XCTAssertEqual(L10n.string("Resume", language: "Deutsch"), "Fortsetzen")
        XCTAssertEqual(L10n.string("Paused", language: "Deutsch"), "Pausiert")
        XCTAssertEqual(L10n.string("Settings", language: "Deutsch"), "Einstellungen")
    }

    func testEnglishIsIdentity() {
        XCTAssertEqual(L10n.string("Resume", language: "English"), "Resume")
        XCTAssertEqual(L10n.string("Completed", language: "English"), "Completed")
    }

    func testUnknownLanguageFallsBackToEnglish() {
        // A language with no shipped table resolves through the English table.
        XCTAssertEqual(L10n.string("Resume", language: "Klingon"), "Resume")
    }

    func testUnknownKeyReturnsKeyUnchanged() {
        XCTAssertEqual(L10n.string("A String With No Translation", language: "Deutsch"),
                       "A String With No Translation")
    }

    func testLanguageCodeMapping() {
        XCTAssertEqual(L10n.languageCode(for: "Deutsch"), "de")
        XCTAssertEqual(L10n.languageCode(for: "german"), "de")
        XCTAssertEqual(L10n.languageCode(for: "English"), "en")
        XCTAssertEqual(L10n.languageCode(for: "whatever"), "en")
    }
}
