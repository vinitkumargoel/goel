import Foundation
import ServiceManagement
import GoelCore

/// Registers (or removes) GoelDownloader as a macOS login item so the
/// Settings › General "Launch at login" toggle actually takes effect.
///
/// Uses `SMAppService.mainApp`, the modern (macOS 13+) replacement for the
/// deprecated `SMLoginItemSetEnabled` helper-bundle dance. On macOS 12 and
/// earlier the API is unavailable, so we no-op rather than crash. Registration
/// failures are logged to stderr and otherwise swallowed — a login-item hiccup
/// must never take down the app.
enum LoginItemService {

    /// Enables or disables launch-at-login for the running app bundle.
    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                GoelLog.app.error("Login item update failed",
                                  .flag(enabled, label: "enabling"),
                                  .detail(String(describing: error)))
            }
        }
        // macOS 12 and earlier: SMAppService is unavailable, so this is a no-op.
    }
}
