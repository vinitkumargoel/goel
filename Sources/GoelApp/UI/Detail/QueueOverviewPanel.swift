import SwiftUI
import GoelCore

/// The detail panel with nothing selected: what the whole queue is doing. Its count tiles are
/// also filters, so the overview is a way to get to the rows.
struct QueueOverviewPanel: View {
    /// Wide in the bottom dock, where the parts sit side by side instead of stacked.
    var horizontal = false

    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    /// Read on a timer, not per frame: it is a filesystem call.
    @State private var diskFree: Int64?

    var body: some View {
        let overview = QueueOverview(tasks: vm.tasks) { telemetry.displaySpeed(for: $0) }
        VStack(alignment: .leading, spacing: 0) {
            header(overview)
            ScrollView {
                if horizontal {
                    // Three columns in a wide dock, two in a narrower one, stacked below ~560 pt.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Studio.Space.xl) {
                            VStack(alignment: .leading, spacing: Studio.Space.m) {
                                tiles(overview, columns: 4)
                                remaining(overview)
                            }
                            .frame(minWidth: 300, maxWidth: 420)
                            speedHistory.frame(minWidth: 220, maxWidth: 360)
                            facts.frame(minWidth: 200, maxWidth: 300)
                        }
                        HStack(alignment: .top, spacing: Studio.Space.xl) {
                            VStack(alignment: .leading, spacing: Studio.Space.m) {
                                tiles(overview, columns: 4)
                                remaining(overview)
                            }
                            .frame(minWidth: 250, maxWidth: 420)
                            VStack(alignment: .leading, spacing: Studio.Space.m) {
                                speedHistory
                                facts
                            }
                            .frame(minWidth: 200, maxWidth: 360)
                        }
                        VStack(alignment: .leading, spacing: Studio.Space.ml) {
                            tiles(overview, columns: 4)
                            remaining(overview)
                            speedHistory
                            facts
                        }
                    }
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.bottom, Studio.Space.l)
                } else {
                    VStack(alignment: .leading, spacing: Studio.Space.ml) {
                        tiles(overview, columns: 2)
                        remaining(overview)
                        speedHistory
                        facts
                    }
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.bottom, Studio.Space.l)
                }
            }
        }
        .task(id: vm.settings.defaultSaveDirectory) {
            while !Task.isCancelled {
                let folder = vm.settings.defaultSaveDirectory
                diskFree = await Task.detached(priority: .utility) {
                    DiskSpaceCheck.availableCapacity(forFolder: folder)
                }.value
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func header(_ overview: QueueOverview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Text(L10n.t("Queue overview"))
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Studio.Space.sm) {
                    DetailSpeedText(direction: .down, speed: overview.speed.down)
                    DetailSpeedText(direction: .up, speed: overview.speed.up)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: Studio.Space.s)
            if horizontal { DetailForcedDockNote() }
            HStack(spacing: Studio.Space.hair) {
                DetailDockToggle()
                DetailCloseButton()
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.top, Studio.Space.l)
        .padding(.bottom, Studio.Space.m)
    }

    private func tiles(_ overview: QueueOverview, columns: Int) -> some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: Studio.Space.s), count: columns)
        return LazyVGrid(columns: grid, spacing: Studio.Space.s) {
            QueueCountTile(count: overview.active, title: L10n.t("Active"), spoken: L10n.t("active"),
                           tone: .accent, filter: .active)
            QueueCountTile(count: overview.queued, title: L10n.t("Queued"), spoken: L10n.t("queued"),
                           tone: nil, filter: .queued)
            QueueCountTile(count: overview.done, title: L10n.t("Done"), spoken: L10n.t("done"),
                           tone: .good, filter: .completed)
            QueueCountTile(count: overview.failed, title: L10n.t("Failed"), spoken: L10n.t("failed"),
                           tone: .bad, filter: .failed)
        }
    }

    /// Bytes left, when the queue should be done, and how far the working downloads are.
    private func remaining(_ overview: QueueOverview) -> some View {
        let nothingLeft = overview.remainingBytes == 0 && !overview.hasUnknownSize
        let fraction = DetailQueueProgress.fraction(vm.tasks)
        return HStack(spacing: Studio.Space.l) {
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Text(L10n.t("Remaining")).studioFont(.eyebrow).foregroundStyle(Studio.Palette.ink3)
                Text(nothingLeft ? L10n.t("Nothing left") : overview.remainingBytes.byteString)
                    .studioFont(nothingLeft ? .title3 : .title1)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let done = overview.doneText() {
                    Text(done).studioFont(.small).foregroundStyle(Studio.Palette.ink2)
                }
                if overview.hasUnknownSize {
                    Text(L10n.t("Some downloads haven’t reported a size yet"))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let fraction {
                StudioProgressArc(fraction: fraction, diameter: 64, accessibilityLabel: L10n.t("Queue progress"))
            }
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.vertical, Studio.Space.ml)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    /// The last minute of the combined speed: ↓ filled, ↑ dashed.
    private var speedHistory: some View {
        let history = telemetry.recentGlobalHistory(60)
        let down = history.map(\.down)
        let peak = down.max() ?? 0
        let hasUpload = history.contains { $0.up >= 1 }
        return DetailSection(L10n.t("Download · last 60 s"),
                             detail: history.count > 1 ? L10n.t("peak %@", peak.speedString) : nil) {
            if history.count > 1 {
                StudioSparkline(values: down, secondary: hasUpload ? history.map(\.up) : nil,
                                gridLines: 2, showsEndDot: true,
                                accessibilityLabel: L10n.t("Download speed history"))
                    .frame(height: horizontal ? 56 : 70)
                    .accessibilityValue(L10n.t("peak %@ in the last minute", A11y.speed(peak)))
            } else {
                DetailEmptyLine(text: L10n.t("No samples yet"))
            }
        }
    }

    private var facts: some View {
        DetailFacts {
            DetailFactRow(L10n.t("Disk free"), value: diskFree.map(\.byteString) ?? "—", mono: true)
            DetailFactRow(L10n.t("Speed limit"),
                          value: SpeedProfileText.pill(limitEnabled: vm.settings.speedLimitEnabled,
                                                       profile: vm.settings.selectedProfile))
            DetailFactRow(L10n.t("Queue profile"), value: vm.settings.selectedProfile.name)
        }
    }
}

/// One count of the overview (`.stat`), which applies its sidebar filter when clicked.
private struct QueueCountTile: View {
    let count: Int
    let title: String
    let spoken: String
    let tone: StudioTone?
    let filter: SidebarFilter

    @EnvironmentObject private var vm: AppViewModel
    @State private var hovered = false

    var body: some View {
        let lit = count > 0 ? tone : nil
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            vm.closeServerBrowser()
            vm.filter = filter
        } label: {
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                Text(verbatim: "\(count)")
                    .studioFont(.stat)
                    .foregroundStyle(lit?.foreground ?? Studio.Palette.ink)
                Text(title)
                    .studioFont(.caption.weight(600))
                    .foregroundStyle(lit == .bad ? Studio.Palette.bad : Studio.Palette.ink3)
            }
            .padding(Studio.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(lit == .bad ? Studio.Palette.badSoft
                                   : hovered ? Studio.Palette.segment : Studio.Palette.well))
            .overlay(shape.strokeBorder(lit == .accent ? Studio.Palette.accentLine
                                        : lit == .bad ? Color.clear : Studio.Palette.hairline, lineWidth: 1))
            .studioButtonFocusRing(shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.studioPlain)
        .onHover { hovered = $0 }
        .help(L10n.t("Show %@", filter.accessibilityName))
        .a11yButton(L10n.t("%1$d %2$@", count, spoken), hint: L10n.t("Activate to filter the list."))
    }
}
