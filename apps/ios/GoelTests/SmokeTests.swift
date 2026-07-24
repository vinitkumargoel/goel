import Testing
@testable import Goel

@Suite("Scaffold")
struct SmokeTests {
    @Test("The test target links against the app target")
    @MainActor
    func linksAgainstApp() {
        _ = RootView()
    }
}
