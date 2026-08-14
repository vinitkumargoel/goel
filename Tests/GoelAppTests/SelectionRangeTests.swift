import XCTest
@testable import GoelApp

final class SelectionRangeTests: XCTestCase {

    private struct Row: Identifiable {
        let id: Int
    }

    private let rows = (0..<5).map(Row.init(id:))

    func testRangeRunsForwardFromTheAnchor() {
        XCTAssertEqual(SelectionRange.ids(in: rows, from: 1, through: 3), [1, 2, 3])
    }

    func testRangeRunsBackwardFromTheAnchor() {
        XCTAssertEqual(SelectionRange.ids(in: rows, from: 3, through: 1), [1, 2, 3])
    }

    func testAnchorAndTargetOnTheSameRowSelectThatRow() {
        XCTAssertEqual(SelectionRange.ids(in: rows, from: 2, through: 2), [2])
    }

    func testMissingAnchorFallsBackToTheClickedRow() {
        XCTAssertEqual(SelectionRange.ids(in: rows, from: nil, through: 4), [4])
        // Anchor removed, filtered out or re-sorted away since the click that set it.
        XCTAssertEqual(SelectionRange.ids(in: rows, from: 99, through: 4), [4])
    }

    func testMissingTargetSelectsNothing() {
        XCTAssertTrue(SelectionRange.ids(in: rows, from: 0, through: 99).isEmpty)
    }

    func testEmptyListSelectsNothing() {
        XCTAssertTrue(SelectionRange.ids(in: [Row](), from: nil, through: 1).isEmpty)
    }

    func testNeighborMovesOneRowAndClampsAtBothEnds() {
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: 2, offset: 1), 3)
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: 2, offset: -1), 1)
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: 4, offset: 1), 4)
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: 0, offset: -1), 0)
    }

    func testNeighborWithNoSelectionStartsAtTheNearEdge() {
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: nil, offset: 1), 0)
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: nil, offset: -1), 4)
        // A selection the list no longer shows behaves like no selection at all.
        XCTAssertEqual(SelectionRange.neighbor(in: rows, from: 99, offset: 1), 0)
    }

    func testNeighborOfAnEmptyListIsNil() {
        XCTAssertNil(SelectionRange.neighbor(in: [Row](), from: nil, offset: 1))
    }
}
