import XCTest
import GoelCore
@testable import GoelApp

/// Arrowing through the queue moves a hidden key target, so VoiceOver hears only what the list
/// announces: the row the selection landed on, plus the count once several are selected.
final class KeyboardSelectionAnnouncementTests: XCTestCase {

    #if DEBUG
    @MainActor
    func testAnnouncesTheRowTheKeyboardLandedOn() throws {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        XCTAssertTrue(model.moveSelection(by: 1, extending: false, in: .list))
        let task = try XCTUnwrap(model.selectedTask)
        XCTAssertEqual(model.keyboardSelectionAnnouncement, task.accessibilityIdentityLabel)
    }

    @MainActor
    func testExtendingAddsTheSelectedCount() throws {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        XCTAssertTrue(model.moveSelection(by: 1, extending: true, in: .list))
        let task = try XCTUnwrap(model.selectedTask)
        XCTAssertEqual(model.keyboardSelectionAnnouncement,
                       A11y.sentence(task.accessibilityIdentityLabel, L10n.t("%d selected", 2)))
    }

    @MainActor
    func testNothingSelectedSaysNothing() {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        model.selectNone()
        XCTAssertEqual(model.keyboardSelectionAnnouncement, "")
    }
    #endif
}
