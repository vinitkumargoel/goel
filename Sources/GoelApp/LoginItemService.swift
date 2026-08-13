import Foundation
import ServiceManagement
import GoelCore

enum LoginItemService {

    /// Returns false when macOS refused: the caller must not leave a switch reading ON that
    /// `SMAppService` never registered.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                GoelLog.app.error("Login item update failed",
                                  .flag(enabled, label: "enabling"),
                                  .detail(String(describing: error)))
                // Both calls also throw when the item is already in the requested state.
                return statusMatches(enabled)
            }
        }
        return true
    }

    @available(macOS 13.0, *)
    private static func statusMatches(_ enabled: Bool) -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled: return enabled
        case .notRegistered, .notFound: return !enabled
        // `.requiresApproval` is registered but switched off by the user — it will not launch.
        default: return false
        }
    }
}
