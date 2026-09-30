import Foundation

/// Moves keyboard focus between views that cannot see each other's `@FocusState`.
/// A menu command (Find… ⌘F) posts; the toolbar's search field listens.
/// SwiftUI ignores `.keyboardShortcut` on a `TextField`, so a menu command is the only way in.
enum FocusBus {
    static let focusSearch = Notification.Name("GoelFocusSearch")

    @MainActor
    static func requestSearchFocus() {
        NotificationCenter.default.post(name: focusSearch, object: nil)
    }
}
