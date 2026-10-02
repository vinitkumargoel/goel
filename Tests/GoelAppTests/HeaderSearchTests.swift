import XCTest
@testable import GoelApp

/// The header's omnibox with Search hidden under Customize: folded until it has something to show.
final class HeaderSearchTests: XCTestCase {
    func testShownSearchAlwaysShowsTheOmnibox() {
        XCTAssertTrue(HeaderSearch.showsOmnibox(searchShown: true, isOpened: false, text: "",
                                                hasClipboardSuggestion: false))
    }

    func testHiddenSearchFoldsWhenIdle() {
        XCTAssertFalse(HeaderSearch.showsOmnibox(searchShown: false, isOpened: false, text: "",
                                                 hasClipboardSuggestion: false))
    }

    func testHiddenSearchUnfoldsWhenOpened() {
        XCTAssertTrue(HeaderSearch.showsOmnibox(searchShown: false, isOpened: true, text: "",
                                                hasClipboardSuggestion: false))
    }

    /// A search in progress or links being added must not vanish when the field loses focus.
    func testHiddenSearchStaysOpenWhileItHoldsText() {
        XCTAssertTrue(HeaderSearch.showsOmnibox(searchShown: false, isOpened: false, text: "ubuntu",
                                                hasClipboardSuggestion: false))
    }

    /// The copied-link suggestion lives in the omnibox: paste-to-add keeps working with Search hidden.
    func testHiddenSearchUnfoldsForACopiedLink() {
        XCTAssertTrue(HeaderSearch.showsOmnibox(searchShown: false, isOpened: false, text: "",
                                                hasClipboardSuggestion: true))
    }

    func testSearchIsCustomizable() {
        XCTAssertTrue(HeaderCustomizePopover.customizable.contains(.search))
    }
}
