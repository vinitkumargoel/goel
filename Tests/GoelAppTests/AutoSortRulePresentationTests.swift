import XCTest
import GoelCore
@testable import GoelApp

final class AutoSortRulePresentationTests: XCTestCase {

    func testHistoryBecomesCandidatesWithHost() {
        let entry = HistoryEntry(id: UUID(), name: "a.dmg", locator: "https://GitHub.com/x/a.dmg", kind: .http,
                                 totalBytes: 10, savePath: "/tmp/a.dmg", completedAt: Date())
        let candidate = AutoSortRulePresentation.candidates(from: [entry])[0]
        XCTAssertEqual(candidate.host, "github.com")
        XCTAssertEqual(candidate.fileExtension, "dmg")
        XCTAssertEqual(candidate.size, 10)
    }

    func testMovingClampsAtTheEnds() {
        let rules = ["a", "b", "c"].map { AutoSortRule(name: $0, conditions: []) }
        XCTAssertEqual(AutoSortRulePresentation.moving(rules[2].id, by: -1, in: rules).map(\.name), ["a", "c", "b"])
        XCTAssertEqual(AutoSortRulePresentation.moving(rules[0].id, by: -1, in: rules).map(\.name), ["a", "b", "c"])
        XCTAssertEqual(AutoSortRulePresentation.moving(rules[0].id, by: 5, in: rules).map(\.name), ["b", "c", "a"])
    }

    func testCanSaveNeedsNameConditionAndAction() {
        var rule = AutoSortRule(name: "Apps", conditions: [.init(field: .fileExtension, op: .isAnyOf, value: "dmg")])
        XCTAssertFalse(AutoSortRulePresentation.canSave(rule), "no action yet")
        rule.folder = "/Users/me/Installers"
        XCTAssertTrue(AutoSortRulePresentation.canSave(rule))
        rule.name = " "
        XCTAssertFalse(AutoSortRulePresentation.canSave(rule))
    }

    func testSummaryReadsLikeASentence() {
        let rule = AutoSortRule(name: "r", conditions: [.init(field: .fileExtension, op: .isAnyOf, value: "dmg, pkg")],
                                folder: "/Apps", tag: "apps", startPaused: true)
        XCTAssertEqual(AutoSortRulePresentation.summary(rule),
                       "Extension is any of dmg, pkg → /Apps, tag “apps”, start paused")
    }
}
