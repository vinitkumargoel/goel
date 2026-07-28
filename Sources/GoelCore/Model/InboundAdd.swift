import Foundation

/// Trust classifier: web-triggerable channels must never silently enqueue.
public enum InboundAdd: Sendable {

    public enum Origin: Sendable, Equatable {
        case userExplicit
        /// Any web page can fire `goeldownloader://` — always confirm.
        case urlScheme
        case browserSpool
        /// Clipboard-monitor suggestion — confirm/suggest, never auto-queue.
        case clipboard
    }

    public struct Payload: Sendable, Equatable {
        public var lines: String?
        public var torrentFilePath: String?
        public var drainBrowserSpool: Bool

        public init(lines: String? = nil, torrentFilePath: String? = nil,
                    drainBrowserSpool: Bool = false) {
            self.lines = lines
            self.torrentFilePath = torrentFilePath
            self.drainBrowserSpool = drainBrowserSpool
        }

        public var hasContent: Bool {
            let hasLines = !(lines?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasTorrent = !(torrentFilePath?.isEmpty ?? true)
            return hasLines || hasTorrent
        }
    }

    public enum Disposition: Sendable, Equatable {
        case enqueue(Payload)
        case needsConfirmation(Payload)
        case drainSpool
        case ignore
    }

    public static func classify(origin: Origin, payload: Payload) -> Disposition {
        if origin == .browserSpool || payload.drainBrowserSpool {
            // Safe to enqueue unconfirmed: the trust boundary was the local host that wrote the spool.
            return payload.hasContent ? .enqueue(payload.withoutDrainFlag) : .drainSpool
        }
        switch origin {
        case .urlScheme, .clipboard:
            return payload.hasContent ? .needsConfirmation(payload) : .ignore
        case .userExplicit:
            return payload.hasContent ? .enqueue(payload) : .ignore
        case .browserSpool:
            return .drainSpool
        }
    }

    public static func parseSources(from lines: String) -> [DownloadSource] {
        lines.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { BatchExpander.expand($0) }
            .compactMap(DownloadSource.parse)
    }
}

private extension InboundAdd.Payload {
    /// Drain flag cleared, or an enqueued spool payload re-triggers a drain loop downstream.
    var withoutDrainFlag: InboundAdd.Payload {
        InboundAdd.Payload(lines: lines, torrentFilePath: torrentFilePath, drainBrowserSpool: false)
    }
}
