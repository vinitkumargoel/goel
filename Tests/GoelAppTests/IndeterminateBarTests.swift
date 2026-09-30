import XCTest
@testable import GoelApp

final class IndeterminateBarTests: XCTestCase {

    func testIndeterminateBandSweepsFromOffLeftToOffRightAndWraps() {
        let period = IndeterminateBar.period
        XCTAssertEqual(IndeterminateBar.bandOffset(at: 0), -IndeterminateBar.bandFraction, accuracy: 0.0001)
        XCTAssertEqual(IndeterminateBar.bandOffset(at: period * 0.999), 1, accuracy: 0.01)
        XCTAssertEqual(IndeterminateBar.bandOffset(at: period * 3.5), IndeterminateBar.bandOffset(at: period / 2),
                       accuracy: 0.0001)
    }
}
