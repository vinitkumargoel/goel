import Foundation

/// What makes the portal installable: the web app manifest, the service worker and the home-screen
/// icons. Static and secret-free, so — like `/assets/` — served ahead of the auth gate: a browser
/// fetches the manifest without cookies.
extension RemoteRouter {

    static let manifestPath = "/manifest.webmanifest"
    static let serviceWorkerPath = "/sw.js"
    static let iconPrefix = "/icons/"

    static func pwaAsset(path: String) -> Data? {
        switch path {
        case manifestPath:
            return response(status: "200 OK", type: "application/manifest+json",
                            body: Data(manifestJSON.utf8),
                            extraHeaders: ["Cache-Control": "public, max-age=86400"])
        case serviceWorkerPath:
            // Revalidated each load: a stale worker would outlive the bundle it was built with.
            return response(status: "200 OK", type: "application/javascript; charset=utf-8",
                            body: Data(PortalBundle.serviceWorker.utf8),
                            extraHeaders: ["Cache-Control": "no-cache", "Service-Worker-Allowed": "/"])
        default:
            guard path.hasPrefix(iconPrefix) else { return nil }
            let name = String(path.dropFirst(iconPrefix.count))
            // Dictionary lookup, never a path: nothing to traverse.
            guard let b64 = PortalBundle.icons[name],
                  let body = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            else { return notFound() }
            return response(status: "200 OK", type: "image/png", body: body,
                            extraHeaders: ["Cache-Control": "public, max-age=604800"])
        }
    }

    static let manifestJSON = #"""
    {"name":"Goel° downloads","short_name":"Goel°","start_url":"/","scope":"/","display":"standalone",\#
    "background_color":"#15171d","theme_color":"#15171d",\#
    "icons":[{"src":"/icons/icon-192.png","sizes":"192x192","type":"image/png"},\#
    {"src":"/icons/icon-512.png","sizes":"512x512","type":"image/png"}]}
    """#

    /// Matches each theme's `--bg-app`, so the installed app's title bar blends with the page.
    static func themeColor(_ theme: String) -> String {
        switch theme {
        case "frost-light": return "#dfe3ee"
        case "dracula": return "#21222c"
        case "nord": return "#2b303b"
        default: return "#15171d"
        }
    }
}
