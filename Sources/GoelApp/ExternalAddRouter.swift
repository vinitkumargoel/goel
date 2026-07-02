import AppKit
import Foundation
import GoelCore

/// Routes downloads arriving from outside the UI — the `goeldownloader://` URL
/// scheme, `magnet:` links, double-clicked `.torrent` files, and the system
/// Services menu — to the view model through one buffered channel.
///
/// Two safety properties live here:
/// - **Cold-launch buffering.** `application(_:open:)` can fire before the view
///   model registers its observer; posts made before `drainPending` are held
///   and replayed, never dropped.
/// - **Origin-based confirmation.** A `goeldownloader://` link is triggerable
///   by any web page, so those adds are marked `needsConfirmation` and surface
///   as a suggestion banner instead of silently queueing; explicit user
///   actions (Services, drop basket, file opens) queue directly.
@MainActor
enum ExternalAdd {
    static let notification = Notification.Name("GoelExternalAdd")

    /// One delivery: raw add-lines to parse, or an explicit local `.torrent`
    /// file URL (which deliberately bypasses `DownloadSource.parse`'s remote
    /// scheme allowlist — it comes from a real user file-open, not a string).
    /// `drainBrowserSpool` carries no content: it just tells the app to read
    /// the on-disk spool the native-messaging host writes (the spool, not the
    /// world-triggerable URL scheme, is the trust boundary for those adds).
    struct Payload {
        var lines: String?
        var torrentFile: URL?
        var needsConfirmation: Bool
        var drainBrowserSpool: Bool = false
    }

    private static var pending: [Payload] = []
    private static var hasSubscriber = false

    static func post(_ payload: Payload) {
        if hasSubscriber {
            NotificationCenter.default.post(name: notification, object: PayloadBox(payload))
        } else {
            pending.append(payload)
        }
    }

    /// Post raw add-lines from an explicit user action (no confirmation).
    static func post(lines: String) {
        post(Payload(lines: lines, torrentFile: nil, needsConfirmation: false))
    }

    /// Mark the channel live and replay anything buffered before the view
    /// model was ready.
    static func drainPending(_ handler: (Payload) -> Void) {
        hasSubscriber = true
        let buffered = pending
        pending = []
        buffered.forEach(handler)
    }

    /// Notification payload wrapper (Notification.object requires a class).
    final class PayloadBox: NSObject {
        let payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }

    /// Convert an opened URL into a payload, or nil when it carries nothing.
    static func payload(from url: URL) -> Payload? {
        switch url.scheme?.lowercased() {
        case "goeldownloader":
            // goeldownloader://drain-browser-queue — the native-messaging host
            // poking us to read its spool. Deliberately content-free: a web
            // page can trigger the drain, but only a local process can have
            // put anything in the spool.
            if url.host?.lowercased() == "drain-browser-queue" {
                return Payload(lines: nil, torrentFile: nil,
                               needsConfirmation: false, drainBrowserSpool: true)
            }
            // goeldownloader://add?url=<percent-encoded target>. Web pages can
            // trigger this scheme, so the inner target is restricted to
            // remote/magnet sources and the add asks for confirmation.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let target = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let inner = URL(string: target),
                  ["http", "https", "magnet"].contains(inner.scheme?.lowercased() ?? "")
            else { return nil }
            return Payload(lines: target, torrentFile: nil, needsConfirmation: true)
        case "magnet":
            return Payload(lines: url.absoluteString, torrentFile: nil, needsConfirmation: false)
        case "file":
            guard url.pathExtension.lowercased() == "torrent" else { return nil }
            return Payload(lines: nil, torrentFile: url, needsConfirmation: false)
        default:
            // A plain remote URL handed to us directly.
            return Payload(lines: url.absoluteString, torrentFile: nil, needsConfirmation: false)
        }
    }
}

/// The Services-menu provider ("Download with GoelDownloader" on any selected
/// text). Registered as `NSApp.servicesProvider`; the selector name must match
/// the Info.plist `NSMessage` entry.
final class GoelServicesProvider: NSObject {
    @objc func downloadWithGoel(_ pboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text on the pasteboard" as NSString
            return
        }
        Task { @MainActor in ExternalAdd.post(lines: text) }
    }
}
