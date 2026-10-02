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
/// Release builds have no preview state. The type has no values, so `\.mainWindowPreview` is
/// always `nil`, every `preview?.…` read is `nil`, and the window takes each value from its live
/// source. The members exist only so the shared view code compiles unchanged; none can run.
enum MainWindowPreview: Equatable {
    var railExpanded: Bool? { switch self {} }
    var flyout: RailFlyout? { switch self {} }
    var isDropTargeted: Bool { switch self {} }
    var omniboxText: String? { switch self {} }
    var omniboxFocused: Bool { switch self {} }
    var clipboardLink: String? { switch self {} }
    var toolbarSlots: Set<ToolbarSlot>? { switch self {} }
}

extension EnvironmentValues {
    /// Read-only and constant: there is no environment key behind it in release.
    var mainWindowPreview: MainWindowPreview? { nil }
}
#endif
