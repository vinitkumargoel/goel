import SwiftUI

@main
struct GoelApp: App {
    var body: some Scene {
        WindowGroup {
            BootstrapView()
                .preferredColorScheme(.dark)
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
