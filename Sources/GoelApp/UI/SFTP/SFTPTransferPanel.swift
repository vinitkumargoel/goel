import SwiftUI
import AppKit
import GoelCore

/// This server's transfers, docked under the files: a scannable list on the left (active,
/// queued, finished) and the selected transfer's detail on the right — throughput graph and
/// readings, the route, and the server facts behind the numbers.
struct SFTPTransferPanel: View {
    let transfers: [SFTPTransfer]
    let connection: SFTPConnection
    /// Already fetched by the browser for its footer — passed in rather than probed again.
    let volumeSpace: SFTPVolumeSpace?
    /// A snapshot's throughput samples; the app reads the telemetry store.
    var historyOverride: [UUID: [Double]]?

    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var selection: UUID?

    /// Tall enough for the graph plus the fact rows without either column scrolling in the
    /// common case; both columns still scroll, so a short window degrades rather than clips.
    static let panelHeight: CGFloat = 360
    static let listWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            header
            StudioDivider()
            HStack(spacing: 0) {
                transferList
                    .frame(width: Self.listWidth)
                Rectangle().fill(Studio.Palette.hairline).frame(width: 1)
                    .accessibilityHidden(true)
                if let selected {
                    SFTPTransferInspector(transfer: selected, connection: connection,
                                          volumeSpace: volumeSpace,
                                          history: historyOverride?[selected.id] ?? telemetry.sftpHistory(selected.id))
                } else {
                    StudioEmptyState(symbol: "arrow.up.arrow.down", title: L10n.t("No transfer selected"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: Self.panelHeight)
        .studioSurface(.card, radius: Studio.Radius.card, elevation: .card)
        .padding(.horizontal, Studio.Space.gutter)
        .padding(.bottom, Studio.Space.m)
        .onAppear { adoptSelection() }
        // Rows leave the list on cancel and on "Clear finished": without this the inspector
        // would keep rendering a transfer that no longer exists.
        .onChange(of: transfers.map(\.id)) { adoptSelection() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Transfers"))
    }

    /// Falls back rather than blanking: a stale id resolves to the first live transfer.
    private var selected: SFTPTransfer? {
        transfers.first { $0.id == selection } ?? preferredSelection
    }

    /// What a user most likely wants to look at: something still moving, else the first row.
    private var preferredSelection: SFTPTransfer? {
        transfers.first { $0.isActive } ?? transfers.first { $0.isPaused } ?? transfers.first
    }

    private func adoptSelection() {
        if let selection, transfers.contains(where: { $0.id == selection }) { return }
        selection = preferredSelection?.id
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Studio.Space.sm) {
            Text(L10n.t("Transfers"))
                .studioFont(.title3)
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(countSummary)
                .studioFont(.small.tabular)
                .foregroundStyle(Studio.Palette.ink3)
            Spacer(minLength: Studio.Space.s)
            if aggregateSpeed > 0 {
                HStack(spacing: Studio.Space.xxs) {
                    Image(systemName: aggregateGlyph)
                        .font(StudioFonts.font(.ui, size: 11, weight: 700))
                    Text(aggregateSpeed.speedString).studioFont(Studio.TextStyle.mono.weight(650))
                }
                .foregroundStyle(Studio.Palette.accent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.t("Combined speed"))
                .accessibilityValue(A11y.speed(aggregateSpeed))
            }
            if transfers.contains(where: { !$0.occupiesDestination }) {
                Button(L10n.t("Clear")) { vm.clearFinishedSFTPTransfers() }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .accessibilityLabel(L10n.t("Clear finished transfers"))
            }
        }
        .padding(.leading, Studio.Space.l)
        .padding(.trailing, Studio.Space.sm)
        .frame(height: 44)
    }

    private var countSummary: String {
        let running = transfers.filter { $0.state == .running }.count
        let waiting = transfers.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if running > 0 { parts.append(L10n.t("%d active", running)) }
        if waiting > 0 { parts.append(L10n.t("%d queued", waiting)) }
        if parts.isEmpty { parts.append(L10n.t("%d items", transfers.count)) }
        return parts.joined(separator: " · ")
    }

    private var aggregateSpeed: Double {
        transfers.reduce(0) { $0 + ($1.isActive ? $1.displaySpeed : 0) }
    }

    /// One glyph for a mixed batch; a single-direction batch gets its own arrow.
    private var aggregateGlyph: String {
        let directions = Set(transfers.filter(\.isActive).map(\.direction))
        guard directions.count == 1, let only = directions.first else { return "arrow.up.arrow.down" }
        switch only {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .remoteCopy: return "arrow.left.arrow.right"
        }
    }

    // MARK: - Master list

    private var transferList: some View {
        // Resolved once per render: `selected` scans the array, and reading it per row made
        // drawing the list quadratic in the number of transfers.
        let selectedID = selected?.id
        return ScrollView {
            LazyVStack(spacing: Studio.Space.xxs) {
                ForEach(transfers) { transfer in
                    // A real Button, not a tap gesture: the row claims `.isButton`, and only
                    // a Button makes that true for keyboard focus and VoiceOver activation.
                    Button { selection = transfer.id } label: {
                        SFTPTransferListRow(transfer: transfer, server: connection.label,
                                            isSelected: selectedID == transfer.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SFTPTransferMenu(transfer: transfer) }
                }
            }
            .padding(Studio.Space.sm)
        }
        .background(Studio.Palette.well)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Transfer list"))
    }
}

/// The per-transfer context menu, shared by the list and the all-transfers window.
struct SFTPTransferMenu: View {
    @EnvironmentObject private var vm: AppViewModel
    let transfer: SFTPTransfer

    var body: some View {
        if transfer.canPause {
            Button(L10n.t("Pause")) { vm.pauseSFTPTransfer(transfer.id) }
        }
        if transfer.canResume {
            Button(L10n.t("Resume")) { vm.resumeSFTPTransfer(transfer.id) }
        }
        if !transfer.isActive && !transfer.isPaused && transfer.state != .finished {
            Button(L10n.t("Retry")) { vm.retrySFTPTransfer(transfer.id) }
        }
        Button(L10n.t("Show Remote Folder")) { vm.revealSFTPTransfer(transfer) }
        Divider()
        Button(L10n.t("Cancel"), role: .destructive) { vm.requestCancelSFTPTransfer(transfer.id) }
    }
}

/// A list row carries only what survives at 280 pt: identity, route, one bar, one number.
/// Everything else is in the inspector.
struct SFTPTransferListRow: View {
    let transfer: SFTPTransfer
    let server: String
    let isSelected: Bool

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
        HStack(spacing: Studio.Space.sm) {
            SFTPTransferArtwork(transfer: transfer, size: .s)
            VStack(alignment: .leading, spacing: 3) {
                FileNameText(transfer.name, lineLimit: 1)
                    .studioFont(.callout.size(12.5).weight(650))
                    .foregroundStyle(Studio.Palette.ink)
                if transfer.isActive || transfer.isPaused {
                    StudioLinearProgress(fraction: transfer.total > 0 ? transfer.fraction : nil,
                                         tone: transfer.progressTone, height: StudioLinearProgress.thinHeight)
                }
                Text(secondaryLine)
                    .studioFont(.caption)
                    .foregroundStyle(transfer.failureMessage == nil ? Studio.Palette.ink3 : Studio.Palette.bad)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if transfer.total > 0, transfer.isActive || transfer.isPaused {
                Text(transfer.progressLabel)
                    .studioFont(Studio.TextStyle.monoSmall.weight(650))
                    .foregroundStyle(Studio.Palette.ink2)
            }
        }
        .padding(.horizontal, Studio.Space.sm)
        .padding(.vertical, Studio.Space.s)
        .background {
            if isSelected {
                shape.fill(Studio.Palette.card).studioElevation(.card)
            } else if hovered {
                shape.fill(Studio.Palette.segment)
            }
        }
        .overlay { if isSelected { shape.strokeBorder(Studio.Palette.accent, lineWidth: 2) } }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .a11yGroup(label: A11y.sentence(L10n.t(transfer.activityLabel), transfer.name),
                   value: A11y.sentence(transfer.stateLabel,
                                        transfer.total > 0 ? A11y.percent(transfer.fraction) : nil),
                   hint: L10n.t("Shows this transfer’s details."))
        // `.isButton` comes from the enclosing Button; only selection is added here.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "↓ from nas.home · 1m left", "↑ to seedbox · Waiting", or the failure.
    private var secondaryLine: String {
        if let failure = transfer.failureMessage { return failure }
        let route = transfer.routeLine(server: server)
        switch transfer.state {
        case .running:
            if let eta = transfer.etaLabel { return L10n.t("%1$@ · %2$@", route, L10n.t("%@ left", eta)) }
            return transfer.speedLabel.isEmpty ? route : L10n.t("%1$@ · %2$@", route, transfer.speedLabel)
        case .finished:
            return transfer.total > 0
                ? L10n.t("%1$@ · %2$@", L10n.t("Done"), transfer.total.byteString)
                : L10n.t("Done")
        case .cancelled:
            return L10n.t("Cancelled")
        default:
            return L10n.t("%1$@ · %2$@", route, transfer.stateLabel)
        }
    }
}
