import Foundation

/// Trust classifier for downloads arriving from outside the in-app Add box.
///
/// Callers hand over an ``Origin`` (who triggered the add) and a raw
/// ``Payload``; ``classify`` decides whether to queue immediately, ask the
/// user, poke the browser spool, or drop the request. The rules keep
/// web-triggerable channels (`goeldownloader://`, clipboard suggestions) from
/// silently enqueuing work while still letting explicit user actions and the
/// local native-messaging spool through without friction.
public enum InboundAdd: Sendable {

    /// Who initiated the add. Determines the confirmation bar, not the
    /// content allowlist (that lives in ``DownloadSource/parse``).
    public enum Origin: Sendable, Equatable {
        /// Services, drop basket, file open, UI paste accepted — trusted.
        case userExplicit
        /// `goeldownloader://` — any web page can fire this → confirm.
        case urlScheme
        /// Native-messaging spool drain poke — trusted local process.
        case browserSpool
        /// Clipboard-monitor suggestion — confirm/suggest, never auto-queue.
        case clipboard
    }

    /// Raw content for an inbound add. `torrentFilePath` is a path string so
    /// the payload stays trivially `Sendable`/`Equatable` without URL quirks.
    public struct Payload: Sendable, Equatable {
        public var lines: String?
        public var torrentFilePath: String?
        /// Content-free poke: read the on-disk browser-capture spool.
        public var drainBrowserSpool: Bool

        public init(lines: String? = nil, torrentFilePath: String? = nil,
                    drainBrowserSpool: Bool = false) {
            self.lines = lines
            self.torrentFilePath = torrentFilePath
            self.drainBrowserSpool = drainBrowserSpool
        }

        /// True when the payload carries something queueable (text lines or a
        /// local torrent path). Empty / whitespace-only lines count as empty.
        public var hasContent: Bool {
            let hasLines = !(lines?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasTorrent = !(torrentFilePath?.isEmpty ?? true)
            return hasLines || hasTorrent
        }
    }

    /// What the app should do with a classified inbound add.
    public enum Disposition: Sendable, Equatable {
        case enqueue(Payload)
        case needsConfirmation(Payload)
        case drainSpool
        case ignore
    }

    /// Classify trust. Rules:
    /// - `browserSpool` origin or `drainBrowserSpool` → `drainSpool` when
    ///   content-free; `enqueue` when the spool reader already supplied lines
    /// - `urlScheme` → `needsConfirmation` if content present, else `ignore`
    /// - `userExplicit` → `enqueue` if content present, else `ignore`
    /// - `clipboard` → `needsConfirmation` if content present, else `ignore`
    public static func classify(origin: Origin, payload: Payload) -> Disposition {
        if origin == .browserSpool || payload.drainBrowserSpool {
            // Spool drain is normally a content-free poke. If a reader already
            // lifted lines out of the spool, queue them directly — the trust
            // boundary was the local native-messaging host that wrote the file.
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

    /// Parse non-empty lines into ``DownloadSource`` values via the same
    /// `BatchExpander` + ``DownloadSource/parse`` path the app uses for the
    /// Add sheet. Metalink expansion stays in the app layer (network fetch).
    public static func parseSources(from lines: String) -> [DownloadSource] {
        lines.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { BatchExpander.expand($0) }
            .compactMap(DownloadSource.parse)
    }
}

private extension InboundAdd.Payload {
    /// Same content, with the drain flag cleared so an enqueued spool payload
    /// doesn't re-trigger a drain loop downstream.
    var withoutDrainFlag: InboundAdd.Payload {
        InboundAdd.Payload(lines: lines, torrentFilePath: torrentFilePath, drainBrowserSpool: false)
    }
}
