import XCTest
@testable import GoelApp

/// Edit Profile… makes a profile the active one, so a managed lock on the selection must leave
/// only the active profile editable.
final class QueueProfileEditingTests: XCTestCase {
    func testAnyProfileIsEditableWhenTheSelectionIsFree() {
        XCTAssertTrue(AppViewModel.canEditProfile(named: "High", active: "Medium", selectionLocked: false))
        XCTAssertTrue(AppViewModel.canEditProfile(named: "Medium", active: "Medium", selectionLocked: false))
    }

    func testALockedSelectionLeavesOnlyTheActiveProfileEditable() {
        XCTAssertTrue(AppViewModel.canEditProfile(named: "Medium", active: "Medium", selectionLocked: true))
        XCTAssertFalse(AppViewModel.canEditProfile(named: "High", active: "Medium", selectionLocked: true))
    }
}
