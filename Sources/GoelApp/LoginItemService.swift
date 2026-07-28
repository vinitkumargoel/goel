import Foundation
import ServiceManagement
import GoelCore

enum LoginItemService {

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
    }
}
