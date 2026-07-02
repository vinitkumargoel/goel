import Foundation
import SafariServices

/// The native half of the Safari Web Extension.
///
/// Safari runs this in a sandboxed extension process, so — unlike the
/// Chrome/Firefox native-messaging host — it can't write the shared
/// Application Support spool or spawn `open`. What a sandboxed extension CAN do
/// is hand a URL to LaunchServices, so a captured link is passed to the app
/// through its `goeldownloader://add?url=…` scheme. That route is the same one
/// web pages can trigger, so the app shows its add-confirmation for it — the
/// safe default for a browser capture.
///
/// The principal class is referenced by its ObjC name from the appex Info.plist
/// (`NSExtensionPrincipalClass`), hence the explicit `@objc(...)`.
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
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        guard let appURL = components.url else { return false }
        // LaunchServices open of the app's registered scheme — permitted from a
        // sandboxed extension (it's brokered), unlike direct file/spool writes.
        NSWorkspace.shared.open(appURL)
        return true
    }

    private func respond(_ context: NSExtensionContext, ok: Bool) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": ok]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
