import Foundation
import SwiftUI

/// One line of the queue — `visual.html`'s `.row`, and the component T11's Library reuses.
///
/// ```css
/// .row   { padding: 12px 16px; grid-template-columns: 38px 1fr auto; gap: 12px; }
/// .rname { font-size: 15px; font-weight: 570; margin-bottom: 5px; }
/// .track { height: 4px; margin: 7px 0 6px; }
/// .rsub  { font-size: 12.5px; color: var(--ios-label-2); font-variant-numeric: tabular-nums; }
/// .rbtn  { width: 30px; height: 30px; border-radius: 50%; }
/// ```
///
/// Three things about this row are load-bearing and easy to get wrong:
///
/// - **The subtitle is one `Text`, not an `HStack`.** Concatenated `Text` keeps the ember speed
///   segment on the same line-breaking and truncation run as the rest of the status, so nothing
///   can end up on its own line at large content sizes.
/// - **Every figure is `.monospacedDigit()`.** Progress arrives at ~10 Hz. Proportional digits
///   make the whole line shuffle sideways twice a second; that is the jitter `CONVENTIONS.md`
///   calls out.
/// - **No `.frame(height:)` anywhere near the text.** The row grows with Dynamic Type. Only the
///   chip, the bar and the button are fixed, and none of them carry words.
public struct DownloadRow: View {

    /// Where the row is being shown. The Library has no live transfers, so it never draws a
    /// progress track and its trailing control is always the save-out glyph.
    public enum Style: Sendable {
        case queue
        case library
    }

    /// Values off `visual.html` that ``Theme/Metric`` does not carry yet. Named in one place so
    /// no literal appears in a view body — fold them into `Theme.swift` when it is next open.
    private enum Local {
        /// `.row { gap: 12px }` — chip → text, text → button.
        static let columnGap: CGFloat = 12
        /// `.rname { margin-bottom: 5px }` collapsed with `.track { margin-top: 7px }`.
        static let nameToTrack: CGFloat = 7
        /// `.track { margin-bottom: 6px }`.
        static let trackToSubtitle: CGFloat = 6
        /// `.rname { margin-bottom: 5px }` on a trackless row.
        static let nameToSubtitle: CGFloat = 5
        /// `.rbtn { width: 30px; height: 30px }` — the *visible* circle. The tap target is
        /// ``Theme/Metric/minHitTarget``.
        static let button: CGFloat = 30
        /// Every `.rbtn` glyph in the frame draws ~13 pt of ink. SF Symbols do not agree on how
        /// much of their nominal size they fill: a bar-pair or a triangle is drawn to cap height
        /// (~0.72 em), while `square.and.arrow.down` uses its whole canvas. Two nominal sizes,
        /// one optical result.
        static let transportGlyph: CGFloat = 18
        static let trayGlyph: CGFloat = 14
        /// `.rname { letter-spacing: -.012em }` at 15 pt.
        static let nameTracking: CGFloat = -0.18
        /// Half the leading the mockup's `body { line-height: 1.5 }` puts around every text line.
        ///
        /// SF's own line box is about 1.21 em, so a SwiftUI `Text` is ~0.29 em shorter than the
        /// same line in the browser. Left alone, the five rows come out 8 pt tighter than the
        /// frame and the whole list drifts up the screen. Expressed as a fraction of the font
        /// size rather than a fixed inset so it keeps its proportion at every Dynamic Type step.
        static let halfLeading: CGFloat = (1.5 - 1.21) / 2
        /// `.rsub { gap: 5px }` either side of the middle dot.
        static let separator = " · "
    }

    private let download: Download
    private let style: Style
    private let onPrimaryAction: (() -> Void)?

    // The type scale in `Theme.Typo` is fixed-point so a screenshot lines up with the mockup.
    // `Theme.swift` prescribes pairing it with `@ScaledMetric` at the call site, which is what
    // makes the row survive Accessibility XXL instead of ignoring Dynamic Type outright.
    @ScaledMetric(relativeTo: .subheadline) private var nameSize = Theme.Typo.Size.rowTitle
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = Theme.Typo.Size.rowSubtitle

    public init(
        download: Download,
        style: Style = .queue,
        onPrimaryAction: (() -> Void)? = nil
    ) {
        self.download = download
        self.style = style
        self.onPrimaryAction = onPrimaryAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Local.columnGap) {
            content
            trailingButton
        }
        .padding(.vertical, Theme.Metric.rowVerticalPadding)
    }

    // MARK: - Content

    /// Chip plus text, collapsed into a single VoiceOver element. The trailing button stays a
    /// sibling so it keeps its own label and its own activation.
    private var content: some View {
        HStack(alignment: .center, spacing: Local.columnGap) {
            KindIcon(download: download)

            VStack(alignment: .leading, spacing: 0) {
                name
                    .padding(.vertical, nameSize * Local.halfLeading)
                    .padding(.bottom, showsTrack ? Local.nameToTrack : Local.nameToSubtitle)

                if showsTrack {
                    ProgressTrack(fraction: download.fractionComplete, fill: trackFill)
                        .padding(.bottom, Local.trackToSubtitle)
                }

                subtitle
                    .font(.system(size: subtitleSize).monospacedDigit())
                    .foregroundStyle(Theme.Color.label2)
                    // No line limit: at Accessibility XXL the status wraps rather than clipping.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, subtitleSize * Local.halfLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Fmt.percent(download.fractionComplete))
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        Text(download.filename)
            .font(.system(size: nameSize, weight: .semibold))
            .tracking(Local.nameTracking)
            .foregroundStyle(Theme.Color.label1)
            .lineLimit(1)
            // The tail carries the extension and the architecture — `…-amd64.iso` matters far
            // more than the middle of the name, so the middle is what gets dropped.
            .truncationMode(.middle)
    }

    // MARK: - Trailing control

    private var trailingButton: some View {
        Button {
            onPrimaryAction?()
        } label: {
            Circle()
                .fill(Theme.Color.elev2)
                .frame(width: Local.button, height: Local.button)
                .overlay {
                    Image(systemName: primaryAction.symbol)
                        .font(.system(size: primaryAction.glyphSize, weight: .semibold))
                        .foregroundStyle(Theme.Color.label1)
                }
                // The circle is 30 pt; the target is 44 pt. `.contentShape` is what makes the
                // grown area actually hittable rather than merely present.
                .frame(width: Theme.Metric.minHitTarget, height: Theme.Metric.minHitTarget)
                .contentShape(.rect)
                // …and the extra 14 pt is then taken back out of *layout* so the circle still
                // sits flush against the 16 pt gutter, exactly where the frame puts it. Without
                // this the row's progress track loses 7 pt and every circle drifts inboard.
                .padding(.horizontal, -(Theme.Metric.minHitTarget - Local.button) / 2)
        }
        // `.borderless` so a `List` row's own tap gesture does not swallow this button, and so
        // the label is not repainted with the row's accent.
        .buttonStyle(.borderless)
        .disabled(onPrimaryAction == nil)
        .accessibilityLabel("\(primaryAction.verb) \(download.filename)")
    }

    /// The frame's three trailing glyphs. A playable-now video shows ▶ even while it downloads —
    /// its primary action is "watch it", not "stop it".
    private var primaryAction: (symbol: String, verb: String, glyphSize: CGFloat) {
        let save = ("square.and.arrow.down", "Save", Local.trayGlyph)
        if style == .library || download.status == .completed { return save }
        if QueueMedia.isPlayableNow(download) {
            return ("play.fill", "Play", Local.transportGlyph)
        }
        switch download.status {
        case .downloading, .probing, .verifying, .queued:
            return ("pause.fill", "Pause", Local.transportGlyph)
        case .paused, .waitingForWiFi, .failed:
            return ("play.fill", "Resume", Local.transportGlyph)
        case .completed:
            return save
        }
    }

    // MARK: - Progress track

    private var showsTrack: Bool {
        style == .queue && download.status != .completed
    }

    /// Ember for an ordinary transfer, cyan for SFTP, red for a failure, and a flat tertiary grey
    /// for anything parked — the frame's Wi‑Fi row is deliberately colourless.
    private var trackFill: AnyShapeStyle {
        switch download.status {
        case .failed:
            return AnyShapeStyle(Theme.Color.danger)
        case .waitingForWiFi, .paused, .queued:
            return AnyShapeStyle(Theme.Color.label3)
        case .downloading, .probing, .verifying, .completed:
            return download.kind == .sftp || download.kind == .ftp
                ? AnyShapeStyle(Theme.Color.instrument)
                : AnyShapeStyle(Theme.Color.emberGradient)
        }
    }

    // MARK: - Subtitle

    /// One `·`-separated status line. Every string comes from ``Fmt`` so the row, the detail
    /// screen and the widgets can never print the same number two different ways.
    private struct Segment {
        var text: String
        var tint: Color
        var weight: Font.Weight

        init(_ text: String, tint: Color = Theme.Color.label2, weight: Font.Weight = .regular) {
            self.text = text
            self.tint = tint
            self.weight = weight
        }

        /// `.rsub b { color: var(--ios-ember); font-weight: 600 }`
        static func emphasised(_ text: String) -> Segment {
            Segment(text, tint: Theme.Color.ember, weight: .semibold)
        }
    }

    private var segments: [Segment] {
        switch download.status {

        // `Blender-4.2-macOS-arm64.dmg` → "412.3 MB · SHA-256 verified · 2m ago"
        case .completed:
            var parts = [Segment(Fmt.bytes(download.totalBytes ?? download.receivedBytes))]
            if download.checksumVerified { parts.append(Segment("SHA-256 verified")) }
            if let finished = download.completedAt { parts.append(Segment(Fmt.relativeShort(finished))) }
            return parts

        case .failed:
            return [Segment(download.errorMessage ?? download.status.displayName,
                            tint: Theme.Color.danger)]

        // `dataset-imagenet-subset.tar` → "Waiting for Wi‑Fi · 1.4 of 18 GB".
        // No rate and no countdown: nothing is moving, so printing either would be a lie.
        case .waitingForWiFi:
            return [
                Segment(download.status.displayName),
                Segment(Fmt.bytesPair(download.receivedBytes, of: download.totalBytes)),
            ]

        case .paused, .queued, .probing, .verifying:
            return [
                Segment(download.status.displayName),
                Segment(Fmt.bytesPair(download.receivedBytes, of: download.totalBytes)),
            ]

        case .downloading:
            // `keynote-2026-4k-hdr.mp4` → "Playable now · sequential · 23%"
            if QueueMedia.isPlayableNow(download) {
                return [
                    .emphasised("Playable now"),
                    Segment("sequential"),
                    Segment(Fmt.percent(download.fractionComplete)),
                ]
            }
            // `nas-backup-2026-07-14.tar.zst` → "sftp · 12.4 MB/s · 3.9 of 12.6 GB".
            // The transport leads and nothing is emphasised — on a non-HTTP transfer the
            // interesting fact is which protocol it is, not how fast it is going.
            if download.kind == .sftp || download.kind == .ftp {
                return [
                    Segment(download.kind.token),
                    Segment(Fmt.speed(download.currentSpeed)),
                    Segment(Fmt.bytesPair(download.receivedBytes, of: download.totalBytes)),
                ]
            }
            // `ubuntu-24.04.1-desktop-amd64.iso` → "48.2 MB/s · 3.6 of 5.7 GB · 44s left"
            var parts: [Segment] = [
                .emphasised(Fmt.speed(download.currentSpeed)),
                Segment(Fmt.bytesPair(download.receivedBytes, of: download.totalBytes)),
            ]
            if let eta = download.eta { parts.append(Segment(Fmt.eta(eta))) }
            return parts
        }
    }

    private var subtitle: Text {
        let parts = segments
        guard let first = parts.first else { return Text(verbatim: "") }
        var result = styled(first)
        for part in parts.dropFirst() {
            result = result
                + Text(verbatim: Local.separator).foregroundStyle(Theme.Color.label3)
                + styled(part)
        }
        return result
    }

    private func styled(_ segment: Segment) -> Text {
        Text(segment.text)
            .foregroundStyle(segment.tint)
            .fontWeight(segment.weight)
    }

    // MARK: - Accessibility

    /// Filename, then the same status the row prints, comma-separated so VoiceOver pauses where
    /// the middle dots are. The percentage is published separately as the element's *value*, so
    /// progress is never carried by the bar's colour alone.
    private var accessibilityLabel: String {
        let status = segments.map(\.text).joined(separator: ", ")
        return status.isEmpty ? download.filename : "\(download.filename), \(status)"
    }
}

// MARK: - Previews

#Preview("Rows · every state") {
    List(PreviewTransferEngine.fixtures()) { download in
        DownloadRow(download: download, onPrimaryAction: {})
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Theme.Metric.gutter,
                bottom: 0,
                trailing: Theme.Metric.gutter
            ))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Color.separator)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Rows · light") {
    List(PreviewTransferEngine.fixtures()) { download in
        DownloadRow(download: download, onPrimaryAction: {})
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Theme.Metric.gutter,
                bottom: 0,
                trailing: Theme.Metric.gutter
            ))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Color.separator)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Color.ground)
    .preferredColorScheme(.light)
}

#Preview("Rows · Accessibility XXL") {
    List(PreviewTransferEngine.fixtures()) { download in
        DownloadRow(download: download, onPrimaryAction: {})
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Theme.Metric.gutter,
                bottom: 0,
                trailing: Theme.Metric.gutter
            ))
            .listRowBackground(Color.clear)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Color.ground)
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.dark)
}

#Preview("Rows · failed and library") {
    let fixtures = PreviewTransferEngine.fixtures()
    var failed = fixtures[0]
    failed.status = .failed
    failed.errorMessage = "The connection was lost. Tap to retry."
    let finished = fixtures[4]

    return List {
        DownloadRow(download: failed, onPrimaryAction: {})
        DownloadRow(download: finished, style: .library, onPrimaryAction: {})
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
