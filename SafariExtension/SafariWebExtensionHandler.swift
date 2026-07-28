import Foundation
import SafariServices

/// Native half of the Safari Web Extension. Sandboxed, so a captured link reaches
/// the app via `goeldownloader://add`; cookies are dropped (LaunchServices logs URLs).
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]
        let ok = route(message)
        respond(context, ok: ok)
    }

    /// Pull the URL out of the JS message, keep only web/magnet links, and open
    /// the app's add scheme. Returns whether we accepted the link.
    private func route(_ message: [String: Any]?) -> Bool {
        guard let raw = message?["url"] as? String,
              let target = URL(string: raw),
              let scheme = target.scheme?.lowercased(),
              ["http", "https", "magnet"].contains(scheme),
              var components = URLComponents(string: "goeldownloader://add") else {
            return false
        }
        // Only the URL goes in the query, never `message["cookie"]` — this scheme is
        // world-triggerable and logged by LaunchServices, so it can't carry a credential.
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        guard let appURL = components.url else { return false }
        // LaunchServices open of the app's registered scheme — permitted from a
        // sandboxed extension (it's brokered), unlike direct file/spool writes.
        NSWorkspace.shared.open(appURL)
        return true
    }

    /// Always `cookies: false`: this path cannot carry them, and the extension says so
    /// rather than leaving the user wondering why capture returned a login page.
    private func respond(_ context: NSExtensionContext, ok: Bool) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": ok, "cookies": false]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
