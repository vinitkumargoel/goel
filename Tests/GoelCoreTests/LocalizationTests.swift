import XCTest
@testable import GoelCore

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

    func testBaseTableShipsInTheResourceBundle() throws {
        let table = try baseTable()
        XCTAssertGreaterThan(table.count, 1000,
                             "The base table looks truncated — regenerate it with Scripts/extract-l10n-keys.py.")
        // The key *is* the English text, so a row whose value differs is a typo, not a translation.
        for (key, value) in table where key != value {
            XCTFail("en.lproj maps \"\(key)\" to a different string, \"\(value)\"")
        }
    }

    /// The Swift half of the missing-key gate: the portal catches these at compile time via its
    /// key union, but `L10n.t` takes a plain `String`, so only an audit can catch a call site that
    /// was added without regenerating the table.
    func testEveryLiteralKeyInSourceIsInTheBaseTable() throws {
        let table = try baseTable()
        var absent: [String] = []
        var scanned = 0
        for url in try swiftSources() {
            for key in try literalKeys(in: url) {
                scanned += 1
                if table[key] == nil { absent.append("\(url.lastPathComponent): \"\(key)\"") }
            }
        }
        // Without this the audit passes trivially if the scanner or the source path ever breaks.
        XCTAssertGreaterThan(scanned, 1000, "The key scanner found almost nothing to audit.")
        XCTAssert(absent.isEmpty, """
            \(absent.count) L10n.t key(s) are missing from en.lproj/Localizable.strings. \
            Run `python3 Scripts/extract-l10n-keys.py`.
            \(absent.sorted().prefix(20).joined(separator: "\n"))
            """)
    }

    /// The audit above only proves that keys which reached `L10n.t` reached the table. It says
    /// nothing about text that never went through `L10n.t` at all, which is the easier mistake to
    /// make. These AppKit setters have no legitimate raw-literal use — every one is prose a user
    /// reads — so a literal here is always an oversight.
    func testUserFacingAppKitSettersAreLocalized() throws {
        let sinks = ["addButton(withTitle: \"", "messageText = \"", "informativeText = \"",
                     "setAccessibilityLabel(\"", "NSTextField(labelWithString: \""]
        var raw: [String] = []
        for url in try swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where sinks.contains(where: line.contains) {
                raw.append("\(url.lastPathComponent):\(offset + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssert(raw.isEmpty, """
            \(raw.count) user-facing AppKit string(s) bypass L10n.t entirely:
            \(raw.sorted().joined(separator: "\n"))
            """)
    }

    /// Every translation is keyed by English text, so a key the English table doesn't have is one
    /// whose English copy was edited or deleted — the translation is dead and nothing else notices.
    func testTranslationsHaveNoKeysTheBaseTableLacks() throws {
        let base = try baseTable()
        let core = try XCTUnwrap(ResourceBundles.core)
        var orphans: [String] = []
        for code in L10n.supportedLanguages.map(\.code) where code != "en" {
            guard let lproj = core.path(forResource: code, ofType: "lproj") else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: lproj + "/Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: String])
            XCTAssertFalse(table.isEmpty, "\(code).lproj parsed to nothing.")
            orphans += table.keys.filter { base[$0] == nil }.map { "\(code): \"\($0)\"" }
        }
        XCTAssert(orphans.isEmpty, """
            \(orphans.count) translation(s) are keyed to English text that no longer exists. \
            Re-key them against en.lproj or delete them.
            \(orphans.sorted().joined(separator: "\n"))
            """)
    }

    /// `Scripts/extract-l10n-keys.py` reimplements Swift's `"""` dedent rules, and the audit above
    /// skips those literals, so nothing else would notice the reimplementation drifting. Checking
    /// the *shape* of the result catches the two ways it can drift without repeating its logic.
    func testMultilineKeysWereDedentedAndJoined() throws {
        for key in try baseTable().keys {
            XCTAssertFalse(key.contains("\\\n"), "A line continuation survived into \"\(key)\".")
            for line in key.split(separator: "\n") where line.hasPrefix("    ") {
                XCTFail("Source indentation survived into \"\(key)\" on the line \"\(line)\".")
            }
        }
    }

    // MARK: - Helpers

    /// Reads the shipped table rather than the file in `Sources/`, so a resource-bundle wiring
    /// mistake fails here instead of showing up as an unlocalized app.
    private func baseTable() throws -> [String: String] {
        let core = try XCTUnwrap(ResourceBundles.core, "The GoelCore resource bundle did not load.")
        let lproj = try XCTUnwrap(core.path(forResource: "en", ofType: "lproj"),
                                  "en.lproj is not in the GoelCore resource bundle.")
        let data = try Data(contentsOf: URL(fileURLWithPath: lproj + "/Localizable.strings"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "en.lproj/Localizable.strings did not parse.")
    }

    private func swiftSources() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)   // Tests/GoelCoreTests/LocalizationTests.swift
            .deletingLastPathComponent()                // Tests/GoelCoreTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // repository root
            .appendingPathComponent("Sources")
        guard FileManager.default.fileExists(atPath: sources.path) else {
            throw XCTSkip("Sources/ is not beside the test file; nothing to audit.")
        }
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                               includingPropertiesForKeys: nil))
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Mirrors the single-line path of `Scripts/extract-l10n-keys.py`, `+`-joined runs included —
    /// those produce one key, so reading only the first segment would report a phantom miss.
    /// Interpolated and `"""` keys are skipped: the generator owns that grammar, and this only has
    /// to catch the everyday case of a literal added without a regenerate.
    private func literalKeys(in url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var keys: [String] = []
        var search = text.startIndex

        while let call = text.range(of: "L10n.t(", range: search..<text.endIndex) {
            search = call.upperBound
            var index = call.upperBound
            var key = ""

            while true {
                guard let (segment, next) = stringLiteral(in: text, at: index) else {
                    key = ""
                    break
                }
                key += segment
                index = skippingWhitespace(in: text, from: next)
                guard index < text.endIndex, text[index] == "+" else { break }
                index = text.index(after: index)
            }
            if !key.isEmpty { keys.append(key) }
        }
        return keys
    }

    /// Returns the literal's value and the index just past its closing quote, or nil when the
    /// expression is anything else — a `"""` block, an interpolation, a computed key.
    private func stringLiteral(in text: String, at start: String.Index) -> (String, String.Index)? {
        var index = skippingWhitespace(in: text, from: start)
        guard index < text.endIndex, text[index] == "\"", !text[index...].hasPrefix("\"\"\"") else { return nil }

        var value = ""
        index = text.index(after: index)
        while index < text.endIndex, text[index] != "\"" {
            guard text[index] == "\\" else {
                value.append(text[index])
                index = text.index(after: index)
                continue
            }
            index = text.index(after: index)
            guard index < text.endIndex else { return nil }
            if text[index] == "(" { return nil }
            value.append(["n": "\n", "t": "\t"][String(text[index])] ?? text[index])
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        return (value, text.index(after: index))
    }

    private func skippingWhitespace(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        return index
    }
}
