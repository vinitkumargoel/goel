import XCTest
@testable import GoelApp

/// Keyboard rules shared by the Studio pop-up menus (Dropdown, SettingsSelect, header menus).
final class MenuKeyboardTests: XCTestCase {

    func testArrowsStopAtTheEnds() {
        XCTAssertEqual(MenuKeyboard.step(from: 0, by: -1, count: 3), 0)
        XCTAssertEqual(MenuKeyboard.step(from: 0, by: 1, count: 3), 1)
        XCTAssertEqual(MenuKeyboard.step(from: 2, by: 1, count: 3), 2)
    }

    func testFirstArrowWithoutHighlightLandsOnAnEnd() {
        XCTAssertEqual(MenuKeyboard.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(MenuKeyboard.step(from: nil, by: -1, count: 3), 2)
        XCTAssertNil(MenuKeyboard.step(from: nil, by: 1, count: 0))
    }

    func testTypingJumpsToThePrefixIgnoringCaseAndAccents() {
        let titles = ["Low", "Medium", "Médiocre", "High"]
        XCTAssertEqual(MenuKeyboard.match("h", in: titles, from: 0), 3)
        XCTAssertEqual(MenuKeyboard.match("med", in: titles, from: 0), 1)
        XCTAssertEqual(MenuKeyboard.match("medi", in: titles, from: 1), 1, "a longer search stays put")
        XCTAssertEqual(MenuKeyboard.match("medio", in: titles, from: 1), 2)
        XCTAssertNil(MenuKeyboard.match("z", in: titles, from: 0))
    }

    func testRepeatedLetterCyclesThroughMatches() {
        let titles = ["Low", "Medium", "Médiocre", "High"]
        XCTAssertEqual(MenuKeyboard.match("m", in: titles, from: 0), 1)
        XCTAssertEqual(MenuKeyboard.match("mm", in: titles, from: 1), 2)
        XCTAssertEqual(MenuKeyboard.match("mmm", in: titles, from: 2), 1, "wraps around")
    }

    @MainActor
    func testStudioMenuFlattensSectionsAndActsOnlyOnLiveItems() {
        var picked: [String] = []
        let nodes: [DownloadMenuNode] = [
            .section("Sort", [
                .choice("Name", isOn: true) { picked.append("name") },
                .choice("Size", isOn: false) { picked.append("size") },
            ]),
            .divider,
            .button("Disabled", isEnabled: false) { picked.append("disabled") },
            .button("Select All") { picked.append("all") },
        ]
        let lines = DownloadStudioMenuLine.flatten(nodes)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.filter(\.isActionable).map(\.title), ["Name", "Size", "Select All"])
        XCTAssertEqual(lines.firstIndex { $0.isChecked }, 1)
        var closed = 0
        lines[2].activate { closed += 1 }
        lines[4].activate { closed += 1 }
        XCTAssertEqual(picked, ["size"], "a disabled item does nothing")
        XCTAssertEqual(closed, 1)
    }
}
