import SwiftUI
import GoelCore

/// The window's foot: live ↓/↑ totals with a minute of history, the queue's finish time, SFTP
/// transfers, the selection echo, then the speed-limit chip and the queue profile.
struct StatusBar: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed so the finish time redraws on each speed tick (`vm.queueOverview` reads it).
    @EnvironmentObject private var telemetry: TelemetryStore
    @EnvironmentObject private var sftpStore: SFTPTransferStore

    var body: some View {
        HStack(spacing: Studio.Space.ml) {
            StatusSpeedStat(direction: .down)
            StatusSpeedStat(direction: .up)
            queueFinish
                .layoutPriority(1)
            if !activeTransfers.isEmpty { StatusTransfersButton(count: activeTransfers.count) }
            selectionEcho
            Spacer(minLength: Studio.Space.s)
            StatusSpeedLimitChip()
                .fixedSize()
                .layoutPriority(1)
            // The caption goes first when the window is narrow, so the figures beside it don't truncate.
            ViewThatFits(in: .horizontal) {
                Text(L10n.t("Queue profile"))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .accessibilityHidden(true)
            StatusProfilePicker()
                .fixedSize()
        }
        .padding(.leading, Studio.Space.l)
        .padding(.trailing, Studio.Space.ml)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Status bar"))
    }

    private var activeTransfers: [SFTPTransfer] { vm.sftpTransfers.filter { $0.isActive } }

    /// "1.2 GB left · done ≈ 14:32": answers "can I close the lid yet?" without adding up rows.
    @ViewBuilder
    private var queueFinish: some View {
        let overview = vm.queueOverview
        if let done = overview.doneText() {
            Text(L10n.t("%1$@ left · %2$@", overview.remainingBytes.byteString, done))
                .studioFont(.small.tabular)
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
                .help(L10n.t("When the running and queued downloads finish at the current combined speed"))
        }
    }

    /// With the panel closed (or several rows picked) nothing else confirms what is selected.
    @ViewBuilder
    private var selectionEcho: some View {
        // Gate on the cheap set first: filtering the visible rows only pays off when the echo shows.
        if !vm.selection.isEmpty, !vm.detailPanelVisible || vm.selection.count > 1,
           case let selected = vm.selectedTasks, !selected.isEmpty {
            let bytes = selected.reduce(Int64(0)) { $0 + ($1.totalBytes ?? $1.bytesDownloaded) }
            Text(SelectionAggregate.statusLine(count: selected.count, totalBytes: bytes))
                .studioFont(.small.tabular)
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
        }
    }
}

/// "↓ 43 MB/s" with the last minute drawn beside it; the sparkline opens the five-minute graph.
struct StatusSpeedStat: View {
    let direction: SpeedDirection
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var showsHistory = false

    var body: some View {
        let speed = direction.value(telemetry.displayedCombinedSpeed)
        let tint = direction == .down ? Studio.Palette.accent : Studio.Palette.upload
        let history = telemetry.recentGlobalHistory(GlobalSpeedSparkline.inlineWindow).map(direction.value)
        HStack(spacing: Studio.Space.xs) {
            Text(verbatim: "\(direction == .down ? "↓" : "↑") \(speed.speedString)")
                .studioFont(.mono.weight(600))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(minWidth: 78, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(direction == .up ? L10n.t("Total upload speed") : L10n.t("Total download speed"))
                .accessibilityValue(A11y.speed(speed))
            Button { showsHistory.toggle() } label: {
                StudioSparkline(values: history, color: tint)
                    .frame(width: 56, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("Speed over the last 5 minutes"))
            .a11yButton(direction == .down ? L10n.t("Download speed history") : L10n.t("Upload speed history"),
                        hint: L10n.t("Activate to show the last 5 minutes."))
            .accessibilityValue(L10n.t("peak %@ in the last minute", A11y.speed(history.max() ?? 0)))
            .popover(isPresented: $showsHistory, arrowEdge: .top) {
                GlobalSpeedHistoryPopover(telemetry: telemetry)
            }
        }
    }
}

/// "2 SFTP transfers": opens the list of transfers in progress.
struct StatusTransfersButton: View {
    @EnvironmentObject private var vm: AppViewModel
    let count: Int
    @State private var showsTransfers = false
    @State private var hovered = false

    var body: some View {
        Button { showsTransfers.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "server.rack").font(StudioFonts.font(.ui, size: 11, weight: 600))
                Text(count == 1 ? L10n.t("%d SFTP transfer", count) : L10n.t("%d SFTP transfers", count))
                    .studioFont(.small.weight(600).tabular)
            }
            .foregroundStyle(Studio.Palette.upload)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(hovered ? Studio.Palette.uploadSoft : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t("SFTP transfers"))
        .a11yButton(L10n.t("SFTP transfers"), hint: L10n.t("Activate to list transfers in progress."))
        .accessibilityValue(L10n.t("%d in progress", count))
        .popover(isPresented: $showsTransfers, arrowEdge: .bottom) {
            StatusTransfersPopover { showsTransfers = false }
        }
    }
}

struct StatusTransfersPopover: View {
    @EnvironmentObject private var vm: AppViewModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("SFTP Transfers"))
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if vm.sftpTransfers.contains(where: { !$0.isActive }) {
                    Button(L10n.t("Clear")) { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.studio(.ghost, size: .small))
                        .accessibilityLabel(L10n.t("Clear finished transfers"))
                }
            }
            .padding(.horizontal, Studio.Space.ml)
            .padding(.vertical, Studio.Space.sm)
            StudioDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.sftpTransfers) { transfer in
                        SFTPTransferRow(
                            transfer: transfer, density: .compact,
                            serverLabel: vm.server(transfer.connectionID)?.label ?? L10n.t("Server"),
                            onCancel: { vm.requestCancelSFTPTransfer(transfer.id) },
                            onRetry: { vm.retrySFTPTransfer(transfer.id) },
                            onPause: { vm.pauseSFTPTransfer(transfer.id) },
                            onResume: { vm.resumeSFTPTransfer(transfer.id) },
                            onShowRemoteFolder: {
                                close()
                                vm.revealSFTPTransfer(transfer)
                            })
                        StudioDivider()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 320)
        .background(Studio.Palette.cardRaised)
    }
}
