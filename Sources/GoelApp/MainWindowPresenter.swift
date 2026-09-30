import AppKit
import SwiftUI

/// Raises the main window from code that has no view (a banner click, the auto-shutdown countdown).
/// Once the last window is closed only SwiftUI's `openWindow` can build one, and that lives in the
/// environment — so a view that is always alive (the menu-bar label) registers it here.
@MainActor
enum MainWindowPresenter {

    private static var opener: (() -> Void)?

    static func register(_ open: @escaping () -> Void) { opener = open }

    /// The `Settings` window is also `canBecomeMain`, so it must be excluded or it gets raised instead.
    private static let settingsID = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && $0.identifier != settingsID }
    }

    /// Frontmost with a main window on screen: the in-window toast is already saying it.
    static var isShowingMainWindow: Bool {
        NSApp.isActive && mainWindow.map { $0.isVisible && !$0.isMiniaturized } == true
    }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

extension View {
    /// Registers this view's `openWindow` with ``MainWindowPresenter``.
    func registersMainWindowOpener() -> some View { modifier(MainWindowOpenerRegistration()) }
}

private struct MainWindowOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            MainWindowPresenter.register { open(id: MainWindowID.value) }
        }
    }
}
