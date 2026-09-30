import XCTest
@testable import GoelCore

final class RemoteLoginPageTests: XCTestCase {

    func testLoginPageCarriesTheToggleCapsWarningAndBothConnectionLines() {
        let page = RemoteRouter.loginPage(theme: "nord", error: nil)
        XCTAssertTrue(page.contains(#"id="eye""#))
        XCTAssertTrue(page.contains(#"type="button" class="eye""#), "a submit-type toggle would post the form")
        XCTAssertTrue(page.contains(#"aria-pressed="false""#))
        XCTAssertTrue(page.contains(#"aria-controls="p""#))
        XCTAssertTrue(page.contains(#"aria-label="Show password""#))
        XCTAssertTrue(page.contains(#"id="caps" role="status" aria-live="polite" hidden"#))
        XCTAssertTrue(page.contains("Caps Lock is on"))
        // The script picks one by `location.protocol`; without it, the cautious line shows.
        XCTAssertTrue(page.contains(#"<span id="plain">"#))
        XCTAssertTrue(page.contains(#"<span id="secure" class="secure" hidden>"#))
        XCTAssertTrue(page.contains(#"<button type="submit" id="submit">"#))
    }

    /// The CSP is `script-src 'self'; style-src 'self'`: any inline script, handler or style is dead on arrival.
    func testLoginPageStaysInsideTheContentSecurityPolicy() {
        let page = RemoteRouter.loginPage(theme: "nord", error: "x")
        XCTAssertFalse(page.contains("style="))
        XCTAssertFalse(page.contains("<style"))
        XCTAssertNil(page.range(of: #"\son[a-z]+="#, options: .regularExpression), "no inline event handlers")
        let scripts = page.components(separatedBy: "<script").dropFirst()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts.allSatisfy { $0.hasPrefix(" src=") })
    }
}
