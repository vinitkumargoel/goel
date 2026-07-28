import AppKit
import Foundation
import GoelCore

/// Routes downloads arriving from outside the UI (URL scheme, magnets, .torrent opens, Services)
/// through one buffered channel: cold-launch posts are replayed, and web-triggerable adds confirm.
@MainActor
enum ExternalAdd {
    static let notification = Notification.Name("GoelExternalAdd")

    /// One delivery: raw add-lines, or an explicit local `.torrent` URL (bypassing the remote scheme
    /// allowlist). `drainBrowserSpool` is content-free — the on-disk spool is the trust boundary.
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
        guard let payload = fromDisposition(
            InboundAdd.classify(origin: .userExplicit, payload: .init(lines: lines))
        ) else { return }
        post(payload)
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
    /// Trust (confirm vs enqueue vs drain) is decided by ``InboundAdd/classify``.
    static func payload(from url: URL) -> Payload? {
        switch url.scheme?.lowercased() {
        case "goeldownloader":
            // goeldownloader://drain-browser-queue — the host poking us to read its spool. Content-free:
            // a web page can trigger the drain, but only a local process can fill the spool.
            if url.host?.lowercased() == "drain-browser-queue" {
                return fromDisposition(
                    InboundAdd.classify(origin: .browserSpool,
                                        payload: .init(drainBrowserSpool: true))
                )
            }
            // goeldownloader://add?url=<percent-encoded target>. Web pages can trigger this scheme, so the
            // inner target is restricted to remote/magnet sources and the add asks for confirmation.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard let target = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let inner = URL(string: target),
                  ["http", "https", "magnet"].contains(inner.scheme?.lowercased() ?? "")
            else { return nil }
            return fromDisposition(
                InboundAdd.classify(origin: .urlScheme, payload: .init(lines: target))
            )
        case "magnet":
            return fromDisposition(
                InboundAdd.classify(origin: .userExplicit,
                                    payload: .init(lines: url.absoluteString))
            )
        case "file":
            guard url.pathExtension.lowercased() == "torrent" else { return nil }
            return fromDisposition(
                InboundAdd.classify(origin: .userExplicit,
                                    payload: .init(torrentFilePath: url.path))
            )
        default:
            // A plain remote URL handed to us directly (file-open / system handoff).
            return fromDisposition(
                InboundAdd.classify(origin: .userExplicit,
                                    payload: .init(lines: url.absoluteString))
            )
        }
    }

    /// Map an ``InboundAdd/Disposition`` onto the wire `Payload` shape the rest
    /// of the app already consumes. `ignore` becomes nil (drop).
    private static func fromDisposition(_ disposition: InboundAdd.Disposition) -> Payload? {
        switch disposition {
        case .ignore:
            return nil
        case .drainSpool:
            return Payload(lines: nil, torrentFile: nil,
                           needsConfirmation: false, drainBrowserSpool: true)
        case .enqueue(let p):
            return Payload(lines: p.lines,
                           torrentFile: p.torrentFilePath.map { URL(fileURLWithPath: $0) },
                           needsConfirmation: false,
                           drainBrowserSpool: false)
        case .needsConfirmation(let p):
            return Payload(lines: p.lines,
                           torrentFile: p.torrentFilePath.map { URL(fileURLWithPath: $0) },
                           needsConfirmation: true,
                           drainBrowserSpool: false)
        }
    }
}

/// The Services-menu provider ("Download with GoelDownloader"). Registered as
/// `NSApp.servicesProvider`; the selector name must match the Info.plist `NSMessage` entry.
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
