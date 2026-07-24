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
/// **Cookies are deliberately dropped on this path.** The shared JS sends a
/// `cookie` field when the user has granted the optional permission, but the
/// only channel available here is a URL — and a URL carrying a session cookie
/// would be handed to LaunchServices, recorded in its history, and visible to
/// anything that can observe an open. So the handler refuses it and reports
/// `cookies: false`, letting the extension tell the user that signed-in capture
/// needs Chrome or Firefox. Forwarding it would require an app-group container
/// shared with the main app (see the note in the handback); a private
/// credential must not take the scenic route in the meantime.
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
        // Only the URL is ever placed in the query — never `message["cookie"]`.
        // See the type-level note: this scheme is world-triggerable and logged by
        // LaunchServices, so it is not a channel for a bearer credential.
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        guard let appURL = components.url else { return false }
        // LaunchServices open of the app's registered scheme — permitted from a
        // sandboxed extension (it's brokered), unlike direct file/spool writes.
        NSWorkspace.shared.open(appURL)
        return true
    }

    /// `cookies: false` is always reported: this path cannot carry them, and the
    /// extension surfaces that instead of the user wondering why a signed-in
    /// download came back as a login page.
    private func respond(_ context: NSExtensionContext, ok: Bool) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": ok, "cookies": false]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
