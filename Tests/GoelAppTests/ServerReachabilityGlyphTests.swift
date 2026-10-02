import XCTest
@testable import GoelApp

/// A server's state must not be told by colour alone (Differentiate Without Colour).
final class ServerReachabilityGlyphTests: XCTestCase {
    func testEveryStateHasItsOwnSymbol() {
        let states: [ServerReachability] = [.unknown, .online, .offline]
        XCTAssertEqual(Set(states.map(\.studioSymbol)).count, states.count)
    }
}
