import XCTest
import GoelCore
@testable import GoelApp

/// The in-window confirm dialog is modal: while it is up, the menu bar's selection commands
/// (⌘P, ⌥⌘P, Move to Trash …) must not act on the queue behind it.
final class ConfirmDialogModalityTests: XCTestCase {

    #if DEBUG
    @MainActor
    func testSelectionCommandsStandDownWhileConfirmDialogIsUp() {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        model.refreshCommandState()
        XCTAssertTrue(model.commandState.snapshot.selectionCanPause, "the sample selection is downloading")

        model.requestConfirm(title: "Remove?", message: "", confirmTitle: "Remove") {}
        XCTAssertFalse(model.commandState.snapshot.hasSelection)
        XCTAssertFalse(model.commandState.snapshot.selectionCanPause)

        model.confirmRequest = nil
        XCTAssertTrue(model.commandState.snapshot.selectionCanPause)
    }
    #endif
}
