import Foundation
import SwiftUI

/// Row-local media predicates.
///
/// Deliberately **not** an extension on `Download`: that type belongs to T03 and the player,
/// library and detail tasks are being written in parallel. A second agent adding its own
/// `isVideo` to the same type would be a redeclaration; a namespaced enum here cannot collide.
enum QueueMedia {

    /// Containers the T10 player can open. HLS is handled by scheme, not extension.
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m3u8", "m3u",
    ]

    /// The row should wear a video glyph and offer a play button rather than a pause button.
    static func isPlayableVideo(_ download: Download) -> Bool {
        if download.kind == .hls { return true }
        let ext = URL(fileURLWithPath: download.filename).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    /// The mockup's "Playable now" state: a video written in order, so the bytes already on disk
    /// are a valid prefix of a playable file. A parallel-segmented download is full of holes and
    /// is not playable at any percentage, which is exactly why `isSequential` exists.
    static func isPlayableNow(_ download: Download) -> Bool {
        download.isSequential
            && isPlayableVideo(download)
            && !download.status.isTerminal
    }
}

/// The 38 pt rounded chip at the leading edge of a download row — `visual.html`'s `.ic`.
///
/// ```css
/// .ic       { width: 38px; height: 38px; border-radius: 10px; background: var(--ios-elev-2); }
/// .ic.ember { background: rgba(255,107,44,.16); }
/// .ic.cyan  { background: rgba( 90,200,250,.16); }
/// .ic.green { background: rgba( 48,209, 88,.16); }
/// ```
///
/// The chip is the tint at 16 % with the glyph at full strength on top, so the row's transport
/// and outcome are legible before a single word is read. Status outranks kind: a finished SFTP
/// transfer is green with a checkmark, not cyan.
///
/// Purely decorative — the row publishes the same information as text, so this is hidden from
/// VoiceOver rather than given a label nobody asked for.
public struct KindIcon: View {

    /// Values off `visual.html` that ``Theme/Metric`` does not carry yet.
    private enum Local {
        /// `rgba(255,107,44,.16)` — the chip fill is its tint at 16 %.
        static let tintFill: Double = 0.16
        /// The mockup's chip glyphs measure ~15 pt of ink inside the 38 pt chip (its 19 px SVG
        /// box is mostly padding). SF Symbols are nominally sized a little above their ink, so
        /// 0.42 lands on 15 pt rather than the 19 pt a naive half-of-the-chip would draw.
        /// A ratio, not a size, so a T08 or T11 call site passing a different `size` keeps the
        /// proportion.
        static let glyphRatio: CGFloat = 0.42
    }

    private let symbol: String
    private let tint: Color
    /// `true` for the idle chip: a flat `elev2` plate, not a tinted wash.
    private let isNeutral: Bool
    private let size: CGFloat

    /// The pinned shape. `kind` alone cannot tell a `.mp4` served over https from an ISO, so
    /// this path treats only `.hls` as video; use ``init(download:size:)`` when the whole value
    /// is on hand and the frame's video glyph matters.
    public init(kind: Download.Kind, status: Download.Status, size: CGFloat = Theme.Metric.rowIcon) {
        self.init(kind: kind, status: status, isVideo: kind == .hls, size: size)
    }

    /// What the queue and library rows use: it can see the filename, so `keynote-2026-4k-hdr.mp4`
    /// gets the play-rectangle chip the mockup draws instead of a generic transport glyph.
    public init(download: Download, size: CGFloat = Theme.Metric.rowIcon) {
        self.init(
            kind: download.kind,
            status: download.status,
            isVideo: QueueMedia.isPlayableVideo(download),
            size: size
        )
    }

    private init(kind: Download.Kind, status: Download.Status, isVideo: Bool, size: CGFloat) {
        let appearance = Self.appearance(kind: kind, status: status, isVideo: isVideo)
        self.symbol = appearance.symbol
        self.tint = appearance.tint
        self.isNeutral = appearance.isNeutral
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
            .fill(isNeutral
                  ? AnyShapeStyle(Theme.Color.elev2)
                  : AnyShapeStyle(tint.opacity(Local.tintFill)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * Local.glyphRatio, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Resolution

    /// Outcome first, then transport. Reading the frame top to bottom: ember download-tray for
    /// HTTP(S), cyan server rack for SFTP, ember play-rectangle for video, a neutral clock while
    /// deferred to Wi‑Fi, and a green checkmark once verified.
    private static func appearance(
        kind: Download.Kind,
        status: Download.Status,
        isVideo: Bool
    ) -> (symbol: String, tint: Color, isNeutral: Bool) {
        switch status {
        case .completed:
            return ("checkmark", Theme.Color.success, false)
        case .failed:
            return ("exclamationmark.triangle.fill", Theme.Color.danger, false)
        case .waitingForWiFi:
            // `.ic` with no modifier: flat elev-2 plate, glyph at rgba(235,235,245,.5) ≈ label2.
            return ("clock", Theme.Color.label2, true)
        case .queued, .probing, .downloading, .paused, .verifying:
            break
        }

        switch kind {
        case .sftp, .ftp:
            return ("server.rack", Theme.Color.instrument, false)
        case .hls:
            return ("play.rectangle", Theme.Color.ember, false)
        case .http, .https:
            return isVideo
                ? ("play.rectangle", Theme.Color.ember, false)
                : ("square.and.arrow.down", Theme.Color.ember, false)
        }
    }
}

// MARK: - Previews

#Preview("Chips · every state") {
    let fixtures = PreviewTransferEngine.fixtures()
    return VStack(alignment: .leading, spacing: 14) {
        ForEach(fixtures) { download in
            HStack(spacing: Theme.Metric.gutter) {
                KindIcon(download: download)
                Text(download.filename)
                    .font(Theme.Typo.rowSubtitle)
                    .foregroundStyle(Theme.Color.label2)
            }
        }
        HStack(spacing: Theme.Metric.gutter) {
            KindIcon(kind: .https, status: .failed)
            Text(verbatim: "failed")
                .font(Theme.Typo.rowSubtitle)
                .foregroundStyle(Theme.Color.label2)
        }
    }
    .padding(Theme.Metric.gutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
