import SwiftUI

/// The four-tab shell. `.tint` is set here — without it every control falls back to system
/// blue and the app's identity collapses.
public struct RootView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var app = app

        TabView(selection: $app.selectedTab) {
            QueueView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .tag(AppModel.Tab.downloads)

            LibraryView()
                .tabItem { Label("Library", systemImage: "folder") }
                .tag(AppModel.Tab.library)

            RemoteView()
                .tabItem { Label("Remote", systemImage: "desktopcomputer") }
                .tag(AppModel.Tab.remote)

            SettingsView(scrollTo: app.settingsAnchor)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .tint(Theme.Color.ember)
        // The whole window, sheets and the player cover included: a preference set this high
        // becomes the window's `overrideUserInterfaceStyle`. `system` resolves to nil, which
        // hands appearance back to the device.
        .preferredColorScheme(app.appearance.colorScheme)
        .onOpenURL { app.handle(url: $0) }
        .fullScreenCover(item: $app.playerID) { id in
            PlayerView(downloadID: id)
        }
        .sheet(item: $app.debugScreen) { screen in
            NavigationStack {
                switch screen {
                case .widgets: WidgetGalleryView(scrollTo: app.debugAnchor)
                case .swatches: SwatchView()
                }
            }
        }
    }
}

/// Remote is a real, honest empty state for this milestone. The desktop pairing feature is
/// V1.2 — faking it with dummy content would be worse than saying so.
struct RemoteView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No desktop paired", systemImage: "desktopcomputer")
            } description: {
                Text("Goel° on your Mac or Linux box can hand transfers to your phone and back. Pairing arrives in a later release.")
            } actions: {
                Text("Nothing to configure yet")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Color.label3)
            }
            .navigationTitle("Remote")
        }
    }
}

/// `fullScreenCover(item:)` needs an `Identifiable`, and a bare `UUID` is not one. Rather than
/// weaken `AppModel.playerID` to a bool plus a separate id, conform it here — the identity of a
/// `UUID` is itself.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
