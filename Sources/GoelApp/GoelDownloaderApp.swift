import SwiftUI
import AppKit
import GoelCore

/// The application entry point.
///
/// An SPM `executableTarget` has no `Info.plist` and no `main.swift`, so the
/// `@main` `App` is the sole top-level entry. A small `NSApplicationDelegate`
/// forces the process to behave like a normal foreground GUI app (dock icon +
/// active window) since a bare SwiftUI executable can otherwise launch as a
/// background accessory.
@main
struct GoelDownloaderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 1040, minHeight: 620)
                .preferredColorScheme(viewModel.preferredColorScheme)
                .task { await viewModel.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { GoelCommands(viewModel: viewModel) }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.preferredColorScheme)
                .frame(width: 760, height: 560)
        }
    }
}

/// Forces a normal foreground activation policy and brings the window to front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // Set the "Swarm" dock icon, choosing the light/dark appearance variant,
        // and keep it in sync if the system appearance changes at runtime.
        applyDockIcon()
        appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.applyDockIcon()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Picks the icon variant matching the current effective appearance and sets
    /// it as the dock icon. Falls back silently to the bundled default if a
    /// resource is missing — a missing icon must never crash the app.
    private func applyDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let preferred = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        let fallback = isDark ? "AppIcon-Light" : "AppIcon-Dark"
        let name = Bundle.module.url(forResource: preferred, withExtension: "png") != nil ? preferred : fallback
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

/// Menu-bar commands that mirror the mockup's File / Downloads / View menus and
/// their keyboard shortcuts.
struct GoelCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Download…") { viewModel.isAddSheetPresented = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Downloads") {
            Button("Start All") { viewModel.resumeAll() }
            Button("Pause All") { viewModel.pauseAll() }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Detail Panel") { viewModel.detailPanelVisible.toggle() }
                .keyboardShortcut("i", modifiers: .command)
        }
    }
}
