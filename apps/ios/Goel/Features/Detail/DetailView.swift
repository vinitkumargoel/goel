import SwiftUI

// MARK: - Detail tokens

/// Point values read off the `.d-hero`, `.card`, `.segrow`, `.grid2` and `.btn` rules in
/// `visual.html`'s detail frame.
///
/// `Theme.Metric` owns every value the rest of the app shares. These four are the ones the
/// detail screen alone needs, and they live in one namespace rather than scattered through the
/// view bodies so the frame stays diffable against the mockup. If a second screen ever needs
/// one of them, promote it into `Theme.Metric` instead of copying it.
enum DetailMetric {

    // .d-hero { padding: 8px 16px 18px }
    static let heroTopPadding: CGFloat = 8
    static let heroBottomPadding: CGFloat = 18
    /// .d-hero .fname { margin-bottom: 4px }
    static let heroTitleSpacing: CGFloat = 4
    /// .bignum { margin: 14px 0 2px }
    static let bigNumberTopSpacing: CGFloat = 14
    static let bigNumberBottomSpacing: CGFloat = 2

    // .card { border-radius: 14px; margin: 0 16px 14px; padding: 14px }
    static let cardPadding: CGFloat = 14
    static let cardSpacing: CGFloat = 14
    /// .card h4 { margin: 0 0 12px }
    static let cardTitleSpacing: CGFloat = 12

    // .segrow { grid-template-columns: 26px 1fr 42px; gap: 9px; margin-bottom: 8px }
    static let segmentIDWidth: CGFloat = 26
    static let segmentPercentWidth: CGFloat = 42
    static let segmentColumnSpacing: CGFloat = 9
    static let segmentRowSpacing: CGFloat = 8

    // .grid2 { gap: 12px 10px }  .stat .k { margin-bottom: 3px }
    static let statRowSpacing: CGFloat = 12
    static let statColumnSpacing: CGFloat = 10
    static let statLabelSpacing: CGFloat = 3

    // .actions { gap: 10px }  .btn { padding: 13px; border-radius: 12px }
    static let buttonRadius: CGFloat = 12
    static let buttonVerticalPadding: CGFloat = 13
    static let buttonSpacing: CGFloat = 10
    /// Gap between the action row and the line explaining why an action is unavailable.
    static let captionSpacing: CGFloat = 6
    /// Opacity of a filled button whose action is genuinely unavailable.
    static let disabledOpacity: Double = 0.4

    // .spark { height: 44px }  stroke-width 2  circle r 3.2  stop-opacity .42
    static let sparklineHeight: CGFloat = 44
    static let sparklineLineWidth: CGFloat = 2
    static let sparklineEndpointRadius: CGFloat = 3.2
    static let sparklineAreaOpacity: Double = 0.42

    // .live .sbar i::after — rgba(255,255,255,.42), sheen 1.9s linear infinite,
    // @keyframes sheen { from { translateX(-100%) } to { translateX(340%) } }
    static let sheenOpacity: Double = 0.42
    static let sheenPeriod: Double = 1.9
    static let sheenStart: Double = -1.0
    static let sheenTravel: Double = 4.4

    /// Duration a segment bar takes to glide to a new value. Bars never snap.
    static let barGrowth: Double = 0.35
}

/// Type the detail screen needs that is not in the shared scale, expressed in terms of
/// `Theme.Typo.Size` wherever a shared size already exists.
enum DetailTypo {
    /// .d-hero .rate { font-size: 14px; font-weight: 600 }
    static let rate = Font.system(size: 14, weight: .semibold).monospacedDigit()
    /// .segrow .sid { font-family: mono; font-size: 9.5px }
    static let segmentID = Font.system(size: 9.5, weight: .regular, design: .monospaced)
    /// .segrow .spct { font-family: mono; font-size: 10px; tabular }
    static let segmentPercent = Font.system(size: 10, weight: .regular, design: .monospaced)
        .monospacedDigit()
    /// .btn { font-size: 16px; font-weight: 620 }
    static let button = Font.system(size: Theme.Typo.Size.statValue, weight: .semibold)
    /// letter-spacing: -.02em at 19 pt.
    static let titleTracking: CGFloat = -0.38
    /// letter-spacing: -.03em at 52 pt.
    static let bigNumberTracking: CGFloat = -1.56
}

// MARK: - Card chrome

/// The screen's card: `elev1`, radius 14, 14 pt padding, an optional tracked uppercase heading.
struct DetailCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DetailMetric.cardTitleSpacing) {
            if let title {
                Text(title.uppercased())
                    .font(Theme.Typo.sectionLabel)
                    .tracking(Theme.Typo.sectionTracking)
                    .foregroundStyle(Theme.Color.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DetailMetric.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
                .fill(Theme.Color.elev1)
        )
    }
}

// MARK: - Detail

/// The signature screen: one transfer, drawn as the parallel connections that actually move it.
///
/// Everything on it is derived from the single `Download` value in the store — there is no
/// separate view model and no local copy of engine state, so a progress tick from the engine
/// repaints the hero, the bars, the sparkline and the stats from one source.
public struct DetailView: View {

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let downloadID: UUID

    /// Resolved off the main render path. Probing the file system inside `body` would `stat`
    /// on every engine tick; this is recomputed only when the transfer's status changes.
    @State private var sharableURL: URL?

    public init(downloadID: UUID) {
        self.downloadID = downloadID
    }

    public var body: some View {
        Group {
            if let download = app.store[downloadID] {
                content(for: download)
                    .task(id: download.status) {
                        sharableURL = Self.completedFileURL(for: download)
                    }
            } else {
                missing
            }
        }
        .background(Theme.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.Color.ember)
        .toolbar { toolbar }
    }

    // MARK: Body

    private func content(for download: Download) -> some View {
        ScrollView {
            VStack(spacing: DetailMetric.cardSpacing) {
                hero(for: download)

                SegmentBars(segments: download.segments, status: download.status)

                DetailCard(title: "Throughput — last 60 s") {
                    Sparkline(samples: download.speedSamples)
                        .frame(height: DetailMetric.sparklineHeight)
                }

                StatsCard(download: download)
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, DetailMetric.cardSpacing)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { actions(for: download) }
    }

    private var missing: some View {
        ContentUnavailableView(
            "Download removed",
            systemImage: "tray",
            description: Text("This transfer is no longer in the queue.")
        )
    }

    // MARK: Hero

    private func hero(for download: Download) -> some View {
        VStack(spacing: 0) {
            Text(download.filename)
                .font(Theme.Typo.detailTitle)
                .tracking(DetailTypo.titleTracking)
                .foregroundStyle(Theme.Color.label1)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.bottom, DetailMetric.heroTitleSpacing)

            Text(Self.sourceLine(for: download))
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Color.label3)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // `verbatim` so the numeral is never locale-formatted away from the mockup.
                Text(verbatim: String(Fmt.percentValue(download.fractionComplete)))
                    .font(Theme.Typo.bigNumber)
                    .tracking(DetailTypo.bigNumberTracking)
                    .foregroundStyle(Theme.Color.label1)
                Text("%")
                    .font(Theme.Typo.bigNumberUnit)
                    .foregroundStyle(Theme.Color.label2)
            }
            .padding(.top, DetailMetric.bigNumberTopSpacing)
            .padding(.bottom, DetailMetric.bigNumberBottomSpacing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Fmt.percentValue(download.fractionComplete)) percent")

            Text(Self.rateLine(for: download))
                .font(DetailTypo.rate)
                .foregroundStyle(
                    download.status.isActive ? Theme.Color.ember : Theme.Color.label2
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DetailMetric.heroTopPadding)
        .padding(.bottom, DetailMetric.heroBottomPadding - DetailMetric.cardSpacing)
    }

    // MARK: Actions

    private func actions(for download: Download) -> some View {
        VStack(spacing: DetailMetric.captionSpacing) {
            HStack(spacing: DetailMetric.buttonSpacing) {
                Button {
                    app.togglePause(downloadID)
                } label: {
                    Text(Self.pauseTitle(for: download))
                        .filledDetailButton(
                            background: AnyShapeStyle(Theme.Color.elev2),
                            foreground: Theme.Color.label1
                        )
                }
                .disabled(Self.pauseIsUnavailable(for: download))
                .opacity(Self.pauseIsUnavailable(for: download) ? DetailMetric.disabledOpacity : 1)

                shareButton(for: download)
            }

            if let reason = shareUnavailableReason(for: download) {
                Text(reason)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Color.label3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, DetailMetric.cardSpacing)
        .padding(.bottom, DetailMetric.buttonSpacing)
        // The mockup's action strip sits on the ground, not on a material — the cards scroll
        // away underneath it rather than blurring through it.
        .background(Theme.Color.ground)
    }

    /// A real `ShareLink` once the bytes exist on disk. Until then the button is visibly
    /// disabled and says why, rather than presenting a sheet over a file that is not there.
    @ViewBuilder
    private func shareButton(for download: Download) -> some View {
        if let url = sharableURL {
            ShareLink(item: url) {
                Text("Share")
                    .filledDetailButton(
                        background: AnyShapeStyle(Theme.Color.ember),
                        foreground: .white
                    )
            }
            .accessibilityLabel("Share \(download.filename)")
        } else {
            Button {} label: {
                Text("Share")
                    .filledDetailButton(
                        background: AnyShapeStyle(Theme.Color.ember),
                        foreground: .white
                    )
            }
            .disabled(true)
            .opacity(DetailMetric.disabledOpacity)
            .accessibilityLabel("Share")
            .accessibilityHint(shareUnavailableReason(for: download) ?? "")
        }
    }

    private func shareUnavailableReason(for download: Download) -> String? {
        guard sharableURL == nil else { return nil }
        return download.status == .completed
            ? "The finished file is not in this device's storage any more."
            : "Sharing unlocks when the file finishes downloading."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let download = app.store[downloadID] {
                    Button(Self.pauseTitle(for: download)) { app.togglePause(downloadID) }
                        .disabled(Self.pauseIsUnavailable(for: download))
                }
                Button("Remove Download", role: .destructive) {
                    app.remove(downloadID)
                    dismiss()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More actions")
        }
    }

    // MARK: Derivation

    /// `releases.ubuntu.com · 3 mirrors`.
    ///
    /// `Download` carries one origin URL, so the mirror count is derived rather than stored:
    /// RFC 2616 §8.1.4 asks a client for at most **two** connections per server, which is why a
    /// six-connection transfer has to be spread across three mirrors in the first place. The
    /// count is therefore `ceil(connections / 2)`, and it is live — drop to two connections and
    /// the line honestly reads `1 mirror`.
    static func sourceLine(for download: Download) -> String {
        let host = download.sourceHost.isEmpty ? download.url.absoluteString : download.sourceHost
        let connections = download.segments.count
        guard connections > 0 else { return host }
        let mirrors = (connections + 1) / 2
        return "\(host) · \(mirrors) \(mirrors == 1 ? "mirror" : "mirrors")"
    }

    /// `48.2 MB/s · 44 s remaining` while bytes are moving; the plain status otherwise, because
    /// a paused transfer has no honest rate to print.
    static func rateLine(for download: Download) -> String {
        guard download.status.isActive, download.currentSpeed > 0 else {
            return download.status.displayName
        }
        let speed = Fmt.speed(download.currentSpeed)
        guard let eta = download.eta else { return speed }
        return "\(speed) · \(Fmt.remainingLong(eta))"
    }

    /// The left button's label. A transfer that cannot be paused says what it is doing instead,
    /// so the disabled control still carries information.
    static func pauseTitle(for download: Download) -> String {
        switch download.status {
        case .paused, .failed: "Resume"
        case .completed: "Completed"
        case .verifying: "Verifying"
        default: "Pause"
        }
    }

    static func pauseIsUnavailable(for download: Download) -> Bool {
        download.status == .completed || download.status == .verifying
    }

    /// The file on disk, or `nil` when it is not there yet.
    ///
    /// `saveDirectory` is a relative folder while a transfer is queued and an absolute path once
    /// the engine reports completion, so both spellings resolve here.
    static func completedFileURL(for download: Download) -> URL? {
        let directory = download.saveDirectory
        let base: URL = directory.hasPrefix("/")
            ? URL(filePath: directory, directoryHint: .isDirectory)
            : URL.documentsDirectory.appending(path: directory, directoryHint: .isDirectory)
        let url = base.appending(path: download.filename, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

// MARK: - Button chrome

private extension View {
    /// `.btn` — 13 pt padding, radius 12, 16 pt semibold, full width.
    ///
    /// The padding is applied *before* the frame so `minHitTarget` acts as a floor on the
    /// finished control rather than adding 26 pt on top of an already 44 pt box.
    func filledDetailButton(background: AnyShapeStyle, foreground: Color) -> some View {
        self
            .font(DetailTypo.button)
            .foregroundStyle(foreground)
            .padding(.vertical, DetailMetric.buttonVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.minHitTarget)
            .background(
                RoundedRectangle(cornerRadius: DetailMetric.buttonRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: DetailMetric.buttonRadius, style: .continuous)
            )
    }
}

// MARK: - Previews

@MainActor
private func detailPreviewModel() -> AppModel {
    let store = DownloadStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-detail-preview.json")
    )
    store.replaceAll(PreviewTransferEngine.fixtures())
    return AppModel(engine: PreviewTransferEngine.makeStatic(), store: store)
}

#Preview("Detail — ubuntu, six segments") {
    let model = detailPreviewModel()
    return NavigationStack {
        DetailView(downloadID: PreviewTransferEngine.ubuntuID)
    }
    .environment(model)
    .preferredColorScheme(.dark)
}

#Preview("Detail — live sheen") {
    let store = DownloadStore(
        persistenceURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-detail-preview-live.json")
    )
    store.replaceAll(PreviewTransferEngine.fixtures())
    let model = AppModel(engine: PreviewTransferEngine.makeLive(), store: store)
    model.startEventPump()
    return NavigationStack {
        DetailView(downloadID: PreviewTransferEngine.ubuntuID)
    }
    .environment(model)
    .preferredColorScheme(.dark)
}

#Preview("Detail — completed") {
    let model = detailPreviewModel()
    return NavigationStack {
        DetailView(downloadID: PreviewTransferEngine.blenderID)
    }
    .environment(model)
    .preferredColorScheme(.dark)
}
