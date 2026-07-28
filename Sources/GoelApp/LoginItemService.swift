import Foundation
import ServiceManagement
import GoelCore

/// Registers/removes GoelDownloader as a login item via `SMAppService.mainApp` (macOS 13+);
/// no-ops on older systems. Failures are logged and swallowed — never take down the app.
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
