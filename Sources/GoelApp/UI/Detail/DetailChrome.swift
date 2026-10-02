import SwiftUI
import AppKit
import GoelCore

/// The detail sheet's head (`.dhead`): artwork, the name, the protocol badge and the state chip,
/// then the dock toggle and the close button.
struct DetailHeader: View {
    let task: DownloadTask
    var artSize: StudioArtSize = .l
    var showsChrome = true
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            DetailTaskArtwork(task: task, size: artSize)
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                DetailTitle(name: task.compactDisplayName)
                HStack(spacing: Studio.Space.xs) {
                    StudioKindBadge(kind: task.kind)
                    StudioStatusChip(state: StudioDownloadState(task: task), detail: Self.chipDetail(task))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11y.sentence(task.accessibilityKindName, task.accessibilityStatusName))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChrome {
                HStack(spacing: 2) {
                    DetailDockToggle()
                    DetailCloseButton()
                }
            }
        }
    }

    /// What the chip says beyond the state's own name, where the state alone is too little.
    static func chipDetail(_ task: DownloadTask) -> String? {
        if task.isFileMissing { return L10n.t("Finished, file missing") }
        switch task.status {
        case .seeding: return task.statusCompactText()
        case .failed where task.bytesDownloaded > 0 && task.totalBytes != nil:
            return L10n.t("Failed at %d%%", task.percentComplete)
        case .paused: return L10n.t("Paused · %d%%", task.percentComplete)
        default: return nil
        }
    }
}

/// The task's artwork tile: faded while paused or missing, ringed while metadata is fetched.
struct DetailTaskArtwork: View {
    let task: DownloadTask
    var size: StudioArtSize = .l

    var body: some View {
        StudioFileArtwork(kind: StudioArtKind(task: task), size: size,
                          isFaded: task.status == .paused || task.isFileMissing,
                          isFetchingMetadata: task.status == .requestingMetadata)
    }
}

/// The download's name as the sheet's heading: two lines broken at the name's separators, middle
/// truncation keeps the extension visible. Copy Name (context menu) copies the exact name — text
/// selection would copy the invisible break opportunities too.
struct DetailTitle: View {
    let name: String

    var body: some View {
        FileNameText(name, lineLimit: 2)
            .studioFont(.headline)
            .foregroundStyle(Studio.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .contextMenu {
                Button(L10n.t("Copy Name"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(name, forType: .string)
                }
            }
    }
}

/// Right or bottom: flips `detailPanelPosition`. A window too narrow for the right dock keeps
/// the panel below, and the toggle says why instead of doing nothing.
struct DetailDockToggle: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let docksRight = vm.effectiveDetailPanelPosition == .right
        let forced = vm.detailDockForcedBottom
        Button {
            vm.toggleDetailPanelPosition()
        } label: {
            Image(systemName: docksRight ? "rectangle.bottomhalf.inset.filled" : "rectangle.trailinghalf.inset.filled")
        }
        .buttonStyle(StudioIconButtonStyle(size: .small))
        .disabled(forced)
        .help(forced ? L10n.t("Widen the window to dock the panel on the right")
              : docksRight ? L10n.t("Dock panel to bottom") : L10n.t("Dock panel to right"))
        .accessibilityLabel(forced
            ? L10n.t("Dock detail panel to the right, unavailable while the window is narrow")
            : docksRight ? L10n.t("Dock detail panel to the bottom") : L10n.t("Dock detail panel to the right"))
        .accessibilityValue(forced ? L10n.t("Docked bottom because the window is narrow")
                            : docksRight ? L10n.t("Currently docked right") : L10n.t("Currently docked bottom"))
    }
}

/// Hides the panel, the same as View ▸ Toggle Detail Panel (⌘I).
struct DetailCloseButton: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        StudioIconButton("xmark", label: L10n.t("Hide detail panel"), size: .small, shortcutHint: "⌘I") {
            vm.detailPanelVisible = false
        }
    }
}

/// The bottom dock's note when the window is too narrow for the right dock.
struct DetailForcedDockNote: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        if vm.detailDockForcedBottom {
            Label(L10n.t("Docked bottom because the window is narrow"), systemImage: "arrow.down.to.line")
                .labelStyle(StudioButtonLabelStyle(spacing: 5, iconSize: 10.5))
                .studioFont(.caption)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }
}

/// Pause / Resume / Retry, Folder and Copy (`.actbar`). The primary verb depends on the state;
/// a finished download has none, so Folder and Copy share the row.
struct DetailActionButtons: View {
    let task: DownloadTask
    var fullWidth = true
    /// The bottom dock has no finished hero, so a finished download leads with Open (or Locate…).
    var completedVerbs = false
    var size: StudioButtonStyle.Size = .regular
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            primary
            Button(L10n.t("Folder"), systemImage: "folder") { vm.revealInFinder(task) }
                .buttonStyle(.studio(.secondary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Show %@ in Finder", task.compactDisplayName))
            Button(L10n.t("Copy"), systemImage: copySymbol) { vm.copyToPasteboard(task.sourceLocator) }
                .buttonStyle(.studio(.secondary, size: size, fullWidth: fullWidth))
                .help(L10n.t("Copy source link for %@", task.compactDisplayName))
                .a11yButton(L10n.t("Copy source link for %@", task.compactDisplayName))
        }
    }

    private var copySymbol: String {
        if case .magnet = task.source { return "link" }
        return "doc.on.doc"
    }

    @ViewBuilder private var primary: some View {
        let name = task.compactDisplayName
        if task.status.isActive {
            Button(L10n.t("Pause"), systemImage: "pause.fill") { vm.pause(task.id) }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Pause %@", name))
        } else if task.status == .paused || task.status == .queued {
            Button(L10n.t("Resume"), systemImage: "play.fill") { vm.resume(task.id) }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Resume %@", name))
        } else if task.status.isFailed {
            Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retry(task.id) }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Retry %@", name))
        } else if completedVerbs && task.isFileMissing {
            Button(L10n.t("Locate…"), systemImage: "magnifyingglass") { vm.locateMissingFile(task) }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Locate %@", task.name))
        } else if completedVerbs && task.status == .completed {
            Button(L10n.t("Open"), systemImage: "arrow.up.forward.app") { vm.openFile(task) }
                .buttonStyle(.studio(.primary, size: size, fullWidth: fullWidth))
                .a11yButton(L10n.t("Open %@", task.name))
        }
    }
}

/// The action bar at the foot of the sheet: on the well, under a hairline.
struct DetailActionBar: View {
    let task: DownloadTask

    var body: some View {
        DetailActionButtons(task: task)
            .padding(.horizontal, Studio.Space.l)
            .padding(.vertical, Studio.Space.m)
            .frame(maxWidth: .infinity)
            .background(Studio.Palette.well)
            .overlay(alignment: .top) { StudioDivider() }
    }
}

/// The last minute of one task's speed as an area chart: ↓ in the accent, ↑ dashed (or ↑ alone
/// while seeding). A running download shows "No samples yet" until there is a line to draw; a
/// stopped one shows the chart only while its last minute had any traffic.
struct DetailThroughputChart: View {
    let taskID: DownloadTask.ID
    var window = 60
    var height: CGFloat = 60
    var alwaysShown = true
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let history = Array(telemetry.taskHistory(taskID).suffix(window))
        let down = history.map(\.down)
        let up = history.map(\.up)
        let peakDown = down.max() ?? 0
        let peakUp = up.max() ?? 0
        let hasLine = history.count > 1 && max(peakDown, peakUp) >= 1
        if hasLine || alwaysShown {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                StudioSectionHeader(L10n.t("Recent throughput"), detail: Self.peakText(down: peakDown, up: peakUp))
                if hasLine {
                    chart(down: down, up: up, peakDown: peakDown, peakUp: peakUp)
                        .frame(height: height)
                        .accessibilityValue(Self.spokenSummary(peakDown >= 1 ? down : up))
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    Text(history.count > 1 ? L10n.t("No transfer in the last minute") : L10n.t("No samples yet"))
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink3)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background {
                            RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
                                .strokeBorder(Studio.Palette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func chart(down: [Double], up: [Double], peakDown: Double, peakUp: Double) -> some View {
        if peakDown >= 1 {
            StudioSparkline(values: down, secondary: peakUp >= 1 ? up : nil, gridLines: 2, showsEndDot: true,
                            accessibilityLabel: L10n.t("Recent throughput"))
        } else {
            StudioSparkline(values: up, gridLines: 2, showsEndDot: true, color: Studio.Palette.upload,
                            fillColor: Studio.Palette.uploadSoft, accessibilityLabel: L10n.t("Recent throughput"))
        }
    }

    static func peakText(down: Double, up: Double) -> String? {
        if down >= 1 { return L10n.t("peak %@", down.speedString) }
        if up >= 1 { return L10n.t("peak %@", "↑ " + up.speedString) }
        return nil
    }

    static func spokenSummary(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return L10n.t("No samples yet") }
        let peak = samples.max() ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        return L10n.t("average %1$@, peak %2$@, over the last %3$@ seconds",
                      A11y.speed(mean), A11y.speed(peak), String(samples.count))
    }
}

/// The tab switcher: Overview · Files · Network, bound through the drawn tab so a Files choice
/// remembered from a torrent shows Overview selected on a single file.
struct DetailTabSwitcher: View {
    @Binding var selection: DetailTab
    let tabs: [DetailTab]

    var body: some View {
        StudioTabBar(
            selection: Binding(get: { tabs.contains(selection) ? selection : .overview },
                               set: { selection = $0 }),
            tabs: tabs.map { StudioSegment($0, title: $0.title) },
            accessibilityLabel: L10n.t("Detail section"))
    }
}
