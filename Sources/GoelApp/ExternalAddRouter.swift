import AppKit
import Foundation
import GoelCore

@MainActor
enum ExternalAdd {
    static let notification = Notification.Name("GoelExternalAdd")

    /// `drainBrowserSpool` is content-free — the on-disk spool is the trust boundary.
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

    static func post(lines: String) {
        guard let payload = fromDisposition(
            InboundAdd.classify(origin: .userExplicit, payload: .init(lines: lines))
        ) else { return }
        post(payload)
    }

    static func drainPending(_ handler: (Payload) -> Void) {
        hasSubscriber = true
        let buffered = pending
        pending = []
        buffered.forEach(handler)
    }

    /// Must stay a class — Notification.object requires one.
    final class PayloadBox: NSObject {
        let payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }

    static func payload(from url: URL) -> Payload? {
        switch url.scheme?.lowercased() {
        case "goeldownloader":
            // A web page can trigger the drain, but only a local process can fill the spool.
            if url.host?.lowercased() == "drain-browser-queue" {
                return fromDisposition(
                    InboundAdd.classify(origin: .browserSpool,
                                        payload: .init(drainBrowserSpool: true))
                )
            }
            // Web pages can trigger this scheme: restrict the inner target and confirm the add.
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
            return fromDisposition(
                InboundAdd.classify(origin: .userExplicit,
                                    payload: .init(lines: url.absoluteString))
            )
        }
    }

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

/// The selector name must match the Info.plist `NSMessage` entry.
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
