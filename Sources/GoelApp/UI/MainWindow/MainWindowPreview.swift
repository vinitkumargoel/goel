import SwiftUI

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

    init(railExpanded: Bool? = nil, flyout: RailFlyout? = nil, isDropTargeted: Bool = false,
         omniboxText: String? = nil, omniboxFocused: Bool = false, clipboardLink: String? = nil) {
        self.railExpanded = railExpanded
        self.flyout = flyout
        self.isDropTargeted = isDropTargeted
        self.omniboxText = omniboxText
        self.omniboxFocused = omniboxFocused
        self.clipboardLink = clipboardLink
    }
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
