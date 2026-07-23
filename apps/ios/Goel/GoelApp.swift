import SwiftUI

@main
struct GoelApp: App {
    var body: some Scene {
        WindowGroup {
            // T02 gate: the swatch screen is the app root until RootView lands in T07.
            // No .preferredColorScheme here — the light/dark screenshots must follow the
            // simulator's appearance setting.
            SwatchView()
        }
    }
}

/// T01 placeholder. Replaced by `RootView` in T07.
struct BootstrapView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Goel°")
                .font(.system(size: 44, weight: .bold, design: .default))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.173))
        }
    }
}
