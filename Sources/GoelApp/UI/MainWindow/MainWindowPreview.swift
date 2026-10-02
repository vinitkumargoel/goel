import SwiftUI

#if DEBUG
/// Frozen window state for the snapshot harness: what would otherwise come from a drag in
/// progress, a click on the rail, the clipboard or UserDefaults. `nil` in the running app, where
/// every value comes from the live source instead. Snapshots set it with
/// `.environment(\.mainWindowPreview, …)`; it also turns off the side effects a render must not
/// run (server probes, temp-file sweeps, the onboarding sheet).
struct MainWindowPreview: Equatable {
    var railExpanded: Bool?
    var flyout: RailFlyout?
    var isDropTargeted = false
    var omniboxText: String?
    var omniboxFocused = false
    /// The empty state's clipboard link, instead of reading the real pasteboard.
    var clipboardLink: String?
    /// The header's Customize choices, instead of the stored ones.
    var toolbarSlots: Set<ToolbarSlot>?
}

private struct MainWindowPreviewKey: EnvironmentKey {
    static let defaultValue: MainWindowPreview? = nil
}

extension EnvironmentValues {
    var mainWindowPreview: MainWindowPreview? {
        get { self[MainWindowPreviewKey.self] }
        set { self[MainWindowPreviewKey.self] = newValue }
    }
}
#else
/// Release builds have no preview state. Nothing can make a value (the init is private) and it
/// stores nothing, so `\.mainWindowPreview` is always `nil`, every `preview?.…` read is `nil`, and
/// the window takes each value from its live source. The members exist only so the shared view
/// code compiles unchanged.
struct MainWindowPreview: Equatable {
    private init() {}

    var railExpanded: Bool? { nil }
    var flyout: RailFlyout? { nil }
    var isDropTargeted: Bool { false }
    var omniboxText: String? { nil }
    var omniboxFocused: Bool { false }
    var clipboardLink: String? { nil }
    var toolbarSlots: Set<ToolbarSlot>? { nil }
}

extension EnvironmentValues {
    /// Read-only and constant: there is no environment key behind it in release.
    var mainWindowPreview: MainWindowPreview? { nil }
}
#endif
