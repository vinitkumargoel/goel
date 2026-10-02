import SwiftUI
import GoelCore

/// Overview: the hero (or the finished hero), the failure card, the last minute of throughput,
/// and the facts.
struct DetailOverviewTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            if task.status == .completed {
                CompletedHero(task: task)
            } else {
                // What went wrong and the next step come first; the progress it stopped at is context.
                if case .failed(let error) = task.status {
                    FailureCard(task: task, error: error)
                    DetailProgressHero(task: task, compact: true)
                } else {
                    DetailProgressHero(task: task)
                }
                DetailThroughputChart(taskID: task.id, alwaysShown: task.status.isActive)
            }
            DetailOverviewFacts(task: task)
        }
    }
}

/// The big read-out (`.hero`): percent in display type, "x of y", speed and time left, and the
/// arc with the state's glyph inside.
struct DetailProgressHero: View {
    let task: DownloadTask
    /// Failed downloads: a smaller read-out beneath the failure card, without the live speed row.
    var compact = false
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let speed = telemetry.displaySpeed(for: task)
        let state = StudioDownloadState(task: task)
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                if task.status == .requestingMetadata {
                    Text(L10n.t("Waiting for metadata…"))
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    bigNumber
                    Text(task.sizeProgressText)
                        .studioFont(.mono)
                        .foregroundStyle(Studio.Palette.ink2)
                        .lineLimit(1)
                        .accessibilityLabel(A11y.sentence(
                            L10n.t("%1$@ of %2$@", A11y.bytes(task.bytesDownloaded), A11y.bytes(task.totalBytes)),
                            A11y.eta(task.estimatedTimeRemaining)))
                }
                if !compact {
                DetailFlowLayout(spacing: Studio.Space.xs, lineSpacing: 2) {
                    if speed.down >= 1 || task.status == .downloading {
                        DetailSpeedText(direction: .down, speed: speed.down)
                    }
                    if speed.up >= 1
                        || (task.kind == .torrent && (task.status == .downloading || task.status == .seeding)) {
                        DetailSpeedText(direction: .up, speed: speed.up)
                    }
                    if let eta = task.estimatedTimeRemaining, eta > 0 {
                        Text(L10n.t("%@ left", DownloadTask.etaString(eta)))
                            .studioFont(.mono)
                            .foregroundStyle(Studio.Palette.ink)
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StudioProgressArc(fraction: task.status == .requestingMetadata ? nil : task.fractionCompleted,
                              tone: StudioProgressTone(task: task), diameter: compact ? 56 : 86,
                              accessibilityLabel: L10n.t("Download progress")) {
                Image(systemName: state.symbol)
                    .font(StudioFonts.font(.ui, size: 20, weight: 650))
                    .foregroundStyle(StudioProgressTone(task: task).color)
                    .accessibilityHidden(true)
            }
            .accessibilityValue(task.accessibilityProgressValue)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(compact ? Studio.Space.m : Studio.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    private var bigNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.hair) {
            Text(verbatim: "\(task.percentComplete)")
                .studioFont(.bigNumber)
                .foregroundStyle(Studio.Palette.ink)
            Text(verbatim: "%")
                .studioFont(.bigNumber.size(20.7).weight(600))
                .foregroundStyle(Studio.Palette.ink2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }
}

/// The facts under the hero: the swarm for a torrent, the request for everything else, then
/// when, where and from where.
struct DetailOverviewFacts: View {
    let task: DownloadTask
    /// The rail's tag colours, so a tag reads the same here as in the sidebar.
    @AppStorage(TagColors.storageKey) private var tagColorsRaw = ""

    var body: some View {
        DetailFacts {
            if task.kind == .torrent {
                DetailFactRow(L10n.t("Share ratio"), value: String(format: "%.2f", task.shareRatio), mono: true)
                DetailFactRow(L10n.t("Uploaded"), value: task.bytesUploaded.byteString, mono: true)
                if !(task.status.isFailed && task.connectionCount == 0) {
                    DetailFactRow(L10n.t("Peers"), value: task.swarmSummary.value, mono: true)
                    DetailFactRow(L10n.t("Leechers"), value: "\(task.leecherCount)", mono: true)
                }
                if let limit = task.seedRatioLimit, limit > 0 {
                    let pct = Int(((task.seedRatioProgress ?? 0) * 100).rounded())
                    DetailFactRow(L10n.t("Seed target"), value: L10n.t("ratio %.1f · %d%%", limit, pct), tone: .upload)
                }
            } else {
                // A failed download holds no connections; "0" says nothing.
                if !(task.status.isFailed && task.connectionCount == 0) {
                    DetailFactRow(L10n.t("Connections"), value: "\(task.connectionCount)", mono: true)
                }
            }
            if let label = task.label {
                DetailFactRow(L10n.t("Label"), value: label, tone: .accent)
            }
            if !task.allTags.isEmpty {
                DetailFactRow(key: L10n.t("Tags"), spokenValue: task.allTags.joined(separator: ", ")) {
                    HStack(spacing: Studio.Space.sm) {
                        ForEach(task.allTags, id: \.self) { tag in
                            StudioTagLabel(name: tag, color: RailTagPalette.color(for: tag, raw: tagColorsRaw))
                        }
                    }
                }
            }
            if let note = task.note, !note.isEmpty {
                DetailFactRow(L10n.t("Note"), value: note)
            }
            if let referer = task.referer, !referer.isEmpty {
                DetailFactRow(L10n.t("Referer"), value: referer, mono: true, copyable: true)
            }
            if let headers = task.requestHeaders, !headers.isEmpty {
                DetailFactRow(L10n.t("Headers"), value: L10n.t("%d custom", headers.count))
            }
            // Cookie STATE only — never the value, and never copyable.
            if let cookies = task.cookieStateText {
                DetailFactRow(L10n.t("Cookies"), value: cookies, tone: task.cookieHeader == nil ? .warn : nil)
            }
            DetailFactRow(L10n.t("Priority"), value: task.priority.title)
            if task.expectedChecksum != nil {
                let checksum = DetailNetworkText.checksum(task)
                DetailFactRow(key: L10n.t("Checksum"), spokenValue: checksum.text) {
                    StudioPill(checksum.text, tone: checksum.tone ?? .neutral, showsDot: false)
                }
            }
            DetailFactRow(L10n.t("Added"), value: task.addedString)
            if task.status == .completed, let completedAt = task.completedAt {
                DetailFactRow(L10n.t("Finished"), value: DownloadTask.addedString(for: completedAt))
                if let took = CompletionSummary.tookLine(bytes: CompletionSummary.size(of: task),
                                                         addedAt: task.addedAt, completedAt: completedAt) {
                    DetailFactRow(L10n.t("Took"), value: took)
                }
            }
            DetailFactRow(L10n.t("Save path"), value: task.savePath,
                          display: (task.savePath as NSString).abbreviatingWithTildeInPath,
                          mono: true, copyable: true)
            DetailFactRow(L10n.t("Source"), value: task.sourceLocator, display: Self.shortSource(task),
                          mono: true, copyable: true)
        }
    }

    /// The source without its scheme, so the host leads: "releases.ubuntu.com/24.04.1/…".
    static func shortSource(_ task: DownloadTask) -> String {
        let locator = task.sourceLocator
        if case .magnet = task.source { return locator }
        guard let range = locator.range(of: "://") else { return locator }
        return String(locator[range.upperBound...])
    }
}
