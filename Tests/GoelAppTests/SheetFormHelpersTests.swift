import XCTest
import GoelCore
@testable import GoelApp

final class AddSheetInputTests: XCTestCase {

    func testAMultiLineClipboardOfLinksIsPrefilledWhole() {
        XCTAssertEqual(
            AddSheetInput.clipboardPrefill("https://e.test/a.zip\nhttps://e.test/b.zip\n"),
            "https://e.test/a.zip\nhttps://e.test/b.zip")
    }

    func testOnlyTheLinesThatParseAreKept() {
        XCTAssertEqual(
            AddSheetInput.clipboardPrefill("Here are the files:\r\n  https://e.test/a.zip  \r\nthanks!"),
            "https://e.test/a.zip")
    }

    func testPatternsAndMagnetsCount() {
        XCTAssertEqual(AddSheetInput.clipboardPrefill("https://e.test/f[1-3].zip"),
                       "https://e.test/f[1-3].zip")
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(AddSheetInput.clipboardPrefill(magnet), magnet)
    }

    func testProseAndEmptyClipboardsAreNotPrefilled() {
        XCTAssertNil(AddSheetInput.clipboardPrefill(nil))
        XCTAssertNil(AddSheetInput.clipboardPrefill(""))
        XCTAssertNil(AddSheetInput.clipboardPrefill("  \n\t "))
        XCTAssertNil(AddSheetInput.clipboardPrefill("just some copied words"))
    }

    func testAdvancedOptionsOpenOnlyWhenOneOfThemHasContent() {
        XCTAssertFalse(AddSheetInput.advancedHasContent(checksum: "", mirrors: "", cookieSource: .none))
        XCTAssertFalse(AddSheetInput.advancedHasContent(checksum: "  ", mirrors: "\n \n", cookieSource: .none))
        XCTAssertTrue(AddSheetInput.advancedHasContent(checksum: "abc", mirrors: "", cookieSource: .none))
        XCTAssertTrue(AddSheetInput.advancedHasContent(checksum: "", mirrors: "https://m.test/a", cookieSource: .none))
        XCTAssertTrue(AddSheetInput.advancedHasContent(checksum: "", mirrors: "", cookieSource: .manual))
        XCTAssertTrue(AddSheetInput.advancedHasContent(checksum: "", mirrors: "", cookieSource: .browser))
        XCTAssertTrue(AddSheetInput.advancedHasContent(checksum: "", mirrors: "", cookieSource: .none,
                                                       hasCapturedCookies: true),
                      "cookies the browser captured with the link are worth showing")
    }

    func testResolveFailureNamesTheHostAndKeepsTheReason() {
        XCTAssertEqual(
            AddSheetInput.resolveFailureMessage(host: "cdn.example.org", reason: "The request timed out."),
            "Couldn’t get details from cdn.example.org. The request timed out.")
    }

    func testResolveFailureDoesNotRepeatTheGenericUnreachableNote() {
        XCTAssertEqual(
            AddSheetInput.resolveFailureMessage(
                host: "cdn.example.org",
                reason: "Couldn’t reach the server — it may still work when you start.",
                isGenericUnreachable: true),
            "Couldn’t reach cdn.example.org. It may still work when you start.")
    }

    func testResolveFailureKeepsASpecificReasonThatHappensToMentionReach() {
        // Only the structured flag rephrases; the words themselves don't.
        XCTAssertEqual(
            AddSheetInput.resolveFailureMessage(host: "cdn.example.org", reason: "Couldn’t reach port 8443."),
            "Couldn’t get details from cdn.example.org. Couldn’t reach port 8443.")
    }

    func testResolveFailureWithoutAHostIsJustTheReason() {
        XCTAssertEqual(AddSheetInput.resolveFailureMessage(host: nil, reason: " HTTP 403 "), "HTTP 403")
        XCTAssertEqual(AddSheetInput.resolveFailureMessage(host: "", reason: "HTTP 403"), "HTTP 403")
    }
}

final class RemoteNameInputTests: XCTestCase {

    func testEmptyAndWhitespaceOnlyNamesAreRefused() {
        XCTAssertFalse(RemoteNameInput.isAcceptable(""))
        XCTAssertFalse(RemoteNameInput.isAcceptable("   "))
        XCTAssertFalse(RemoteNameInput.isAcceptable("\n\t "))
    }

    func testAnyVisibleCharacterIsAccepted() {
        XCTAssertTrue(RemoteNameInput.isAcceptable("a"))
        XCTAssertTrue(RemoteNameInput.isAcceptable("  photos  "))
        XCTAssertTrue(RemoteNameInput.isAcceptable(RemoteNameInput.defaultFolderName))
    }
}

final class SFTPConnectionFormTests: XCTestCase {

    func testSaveIsAllowedWithHostUsernameAndAValidPort() {
        XCTAssertNil(SFTPConnectionForm.saveBlocker(host: "h", username: "u", portIsValid: true))
    }

    func testEachMissingPieceIsNamed() {
        XCTAssertEqual(SFTPConnectionForm.saveBlocker(host: "", username: "", portIsValid: true),
                       "Enter a host and username to save.")
        XCTAssertEqual(SFTPConnectionForm.saveBlocker(host: "", username: "u", portIsValid: true),
                       "Enter a host to save.")
        XCTAssertEqual(SFTPConnectionForm.saveBlocker(host: "h", username: "", portIsValid: false),
                       "Enter a username to save.")
        XCTAssertEqual(SFTPConnectionForm.saveBlocker(host: "h", username: "u", portIsValid: false),
                       "Fix the port to save.")
    }
}

final class SettingsSearchTests: XCTestCase {

    private func search(_ q: String) -> [SettingsView.Pane] {
        SettingsSearch.panes(matching: q, localize: { $0 })
    }

    func testAnEmptyQueryListsEveryPaneExactlyOnce() {
        let all = search("  ")
        XCTAssertEqual(all.count, SettingsView.Pane.allCases.count)
        XCTAssertEqual(Set(all), Set(SettingsView.Pane.allCases))
    }

    func testEveryPaneBelongsToExactlyOneGroup() {
        let grouped = SettingsView.Pane.Group.allCases.flatMap(\.panes)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(SettingsView.Pane.allCases))
    }

    func testEveryPaneHasKeywords() {
        for pane in SettingsView.Pane.allCases {
            XCTAssertFalse(pane.searchKeywords.isEmpty, pane.rawValue)
        }
    }

    func testRowTitlesFindTheirPane() {
        XCTAssertEqual(search("proxy host"), [.network])
        XCTAssertEqual(search("DHT"), [.bittorrent])
        XCTAssertEqual(search("audit"), [.audit])
        XCTAssertTrue(search("finish").contains(.scheduler))
    }

    func testMatchingIgnoresCaseDiacriticsAndWordOrder() {
        XCTAssertEqual(search("PROXY PORT"), [.network])
        XCTAssertEqual(search("port proxy"), [.network])
        XCTAssertEqual(search("mode encryption"), [.bittorrent])
        XCTAssertEqual(search("µtp"), [.bittorrent])
    }

    func testTheLocalisedTitleIsSearchedToo() {
        let found = SettingsSearch.panes(matching: "Zeitplan",
                                         localize: { $0 == "Scheduler" ? "Zeitplan" : $0 })
        XCTAssertEqual(found, [.scheduler])
    }

    func testNoMatchIsEmpty() {
        XCTAssertEqual(search("qwertyuiop"), [])
    }

    func testRowHighlightNeedsEveryWord() {
        XCTAssertTrue(SettingsSearch.matches("Proxy host", query: "host"))
        XCTAssertFalse(SettingsSearch.matches("Proxy host", query: "host port"))
        XCTAssertFalse(SettingsSearch.matches("Proxy host", query: "   "))
    }

    func testHighlightingNeedsTwoCharacters() {
        XCTAssertFalse(SettingsSearch.highlights("Proxy host", query: "h"))
        XCTAssertFalse(SettingsSearch.highlights("Proxy host", query: " h "))
        XCTAssertTrue(SettingsSearch.highlights("Proxy host", query: "ho"))
        XCTAssertFalse(SettingsSearch.highlights("", query: "ho"))
    }

    func testTheIndexIsFoldedOnceAndMatchesLikeTheOldScan() {
        let index = SettingsSearch.Index(localize: { $0 })
        XCTAssertEqual(index.panes(matching: "PROXY PORT"), [.network])
        XCTAssertEqual(index.panes(matching: "µtp"), [.bittorrent])
        XCTAssertEqual(index.panes(matching: "ÉNCRYPTION"), [.bittorrent], "diacritics in the query fold away")
        XCTAssertEqual(index.panes(matching: ""), SettingsView.Pane.Group.allCases.flatMap(\.panes))
        for entry in index.entries {
            XCTAssertEqual(entry.keys, entry.keys.map(SettingsSearch.fold), "keys are stored folded")
            XCTAssertEqual(entry.keys.count, Set(entry.keys).count, "no duplicate keys")
        }
    }

    func testEveryWordMustSitInOneKeywordNotAcrossThePane() {
        // "Enable DHT" and "Encryption mode" are both in BitTorrent, but no one keyword has both words.
        XCTAssertEqual(search("dht encryption"), [])
    }

    func testTheCachedIndexIsReusedPerLanguage() {
        let first = SettingsSearch.index(for: "English")
        let again = SettingsSearch.index(for: "English")
        XCTAssertEqual(first.entries.map(\.pane), again.entries.map(\.pane))
        XCTAssertEqual(SettingsSearch.panes(matching: "proxy host"), [.network])
    }

    func testResultAnnouncements() {
        XCTAssertEqual(SettingsSearch.resultAnnouncement(count: 0), "No settings match")
        XCTAssertEqual(SettingsSearch.resultAnnouncement(count: 1), "1 pane matches")
        XCTAssertEqual(SettingsSearch.resultAnnouncement(count: 3), "3 panes match")
    }

    /// Scrapes every `SetRow(name: L10n.t("…"))` title out of the settings pane sources: a row added
    /// without a keyword would be invisible to search.
    func testEverySetRowTitleIsInTheSearchIndex() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GoelApp/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"SetRow\(\s*name:\s*L10n\.t\("((?:[^"\\]|\\.)*)""#)
        let indexed = Set(SettingsView.Pane.allCases.flatMap(\.searchKeywords))
        var titles: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let title = Range(match.range(at: 1), in: source) else { continue }
                titles.append(String(source[title]).replacingOccurrences(of: #"\""#, with: "\""))
            }
        }
        XCTAssertGreaterThan(titles.count, 50, "the scrape found the settings rows")
        let missing = Set(titles).subtracting(indexed).sorted()
        XCTAssertEqual(missing, [], "SetRow titles missing from SettingsView.Pane.searchKeywords")
    }
}
