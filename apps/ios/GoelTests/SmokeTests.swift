import Testing
@testable import Goel

@Suite("Scaffold")
struct SmokeTests {
    @Test("The test target links against the app target")
    func linksAgainstApp() {
        _ = BootstrapView()
    }
}
