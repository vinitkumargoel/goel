import Foundation
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]
        let ok = route(message)
        respond(context, ok: ok)
    }

    private func route(_ message: [String: Any]?) -> Bool {
        guard let raw = message?["url"] as? String,
              let target = URL(string: raw),
              let scheme = target.scheme?.lowercased(),
              ["http", "https", "magnet"].contains(scheme),
              var components = URLComponents(string: "goeldownloader://add") else {
            return false
        }
        // Never put `message["cookie"]` here: this scheme is world-triggerable and LaunchServices-logged.
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        guard let appURL = components.url else { return false }
        // Brokered scheme open is the only handoff a sandboxed extension gets; direct file writes fail.
        NSWorkspace.shared.open(appURL)
        return true
    }

    private func respond(_ context: NSExtensionContext, ok: Bool) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": ok, "cookies": false]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
