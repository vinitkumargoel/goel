import SwiftUI

@main
struct GoelApp: App {
    /// Routes `handleEventsForBackgroundURLSession` into `BackgroundCoordinator`. Without it
    /// iOS terminates the app before the handoff can persist its state (T06).
    @UIApplicationDelegateAdaptor(GoelAppDelegate.self) private var appDelegate
    @State private var model = AppModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}
