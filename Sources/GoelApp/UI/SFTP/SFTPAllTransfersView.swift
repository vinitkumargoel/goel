import SwiftUI
import AppKit
import GoelCore

/// Every server's uploads and downloads in one sheet, grouped by server. Opened from the rail's
/// "Transfers" row.
struct SFTPAllTransfersView: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed so progress and state changes redraw the list.
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.sftpTransfers.isEmpty {
                StudioEmptyState(symbol: "arrow.up.arrow.down", title: L10n.t("No transfers yet"),
                                 message: L10n.t("Uploads and downloads from your servers appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transferList
            }
            StudioSheetFooter(primaryTitle: L10n.t("Done"), onPrimary: { dismiss() }) {
                Button(L10n.t("Clear Finished")) { vm.clearFinishedSFTPTransfers() }
                    .buttonStyle(.studio(.secondary))
                    .disabled(!vm.sftpTransfers.contains { !$0.occupiesDestination })
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 320, idealHeight: 440)
        .background(Studio.Palette.sheet)
    }

    private var header: some View {
        let summary = SFTPTransferSummary(vm.sftpTransfers)
        return HStack(alignment: .center, spacing: Studio.Space.m) {
            Image(systemName: "arrow.up.arrow.down")
                .studioFont(.ui, size: 16, weight: 650)
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Studio.Palette.accentSoft,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Text(L10n.t("Transfers"))
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if summary.total > 0 {
                    Text(A11y.sentence(L10n.t("%d active", summary.active),
                                       summary.failed > 0 ? L10n.t("%d failed", summary.failed) : nil))
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, 18)
        .padding(.bottom, Studio.Space.m)
    }

    private var groups: [(SFTPConnection.ID, [SFTPTransfer])] {
        let grouped = Dictionary(grouping: vm.sftpTransfers, by: \.connectionID)
        return grouped.keys.sorted { serverName($0) < serverName($1) }.map { ($0, grouped[$0] ?? []) }
    }

    private func serverName(_ id: SFTPConnection.ID) -> String {
        vm.server(id)?.label ?? L10n.t("Removed server")
    }

    private var transferList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Studio.Space.ml) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: Studio.Space.s) {
                        HStack(spacing: Studio.Space.xs) {
                            Image(systemName: "server.rack")
                                .studioFont(.ui, size: 10, weight: 700)
                            Text(serverName(group.0))
                        }
                        .studioFont(.eyebrow)
                        .foregroundStyle(Studio.Palette.ink3)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group.1) { transfer in
                            SFTPAllTransfersRow(transfer: transfer)
                        }
                    }
                }
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.bottom, Studio.Space.l)
        }
    }
}

/// One transfer as a small card (`.mcard`): artwork, name, bar, status, and its one action.
private struct SFTPAllTransfersRow: View {
    let transfer: SFTPTransfer
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            SFTPTransferArtwork(transfer: transfer, size: .s)
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                FileNameText(transfer.name, lineLimit: 1)
                    .studioFont(.callout.size(13).weight(650))
                    .foregroundStyle(Studio.Palette.ink)
                StudioLinearProgress(fraction: transfer.fraction, tone: transfer.progressTone,
                                     height: StudioLinearProgress.thinHeight)
                Text(statusLine)
                    .studioFont(.caption)
                    .foregroundStyle(isFailed ? Studio.Palette.bad : Studio.Palette.ink3)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, 11)
        .studioSurface(.card, radius: Studio.Radius.compactCard, elevation: .card)
        .overlay {
            if isFailed {
                RoundedRectangle(cornerRadius: Studio.Radius.compactCard, style: .continuous)
                    .strokeBorder(Studio.Palette.badSoft, lineWidth: 1)
            }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var statusLine: String {
        let sizes = "\(transfer.bytes.byteString) / \(transfer.total.byteString)"
        switch transfer.state {
        case .waiting: return L10n.t("Waiting")
        case .running: return "\(sizes) · \(Int64(transfer.displaySpeed).byteString)/s"
        case .paused: return L10n.t("Paused · %@", sizes)
        case .finished: return L10n.t("Finished · %@", transfer.total.byteString)
        case .failed(let message): return message
        case .cancelled: return L10n.t("Cancelled")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Studio.Space.hair) {
            if transfer.canPause {
                StudioIconButton("pause.fill", label: L10n.t("Pause"), size: .small) {
                    vm.pauseSFTPTransfer(transfer.id)
                }
            } else if transfer.canResume {
                StudioIconButton("play.fill", label: L10n.t("Resume"), size: .small) {
                    vm.resumeSFTPTransfer(transfer.id)
                }
            } else if isFailed {
                StudioIconButton("arrow.clockwise", label: L10n.t("Retry"), size: .small) {
                    vm.retrySFTPTransfer(transfer.id)
                }
            }
            StudioIconButton("folder", label: L10n.t("Show on Server"), size: .small) {
                vm.revealSFTPTransfer(transfer)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L10n.t("Show on Server")) { vm.revealSFTPTransfer(transfer) }
        if let url = transfer.localURL, transfer.state == .finished {
            Button(L10n.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if transfer.occupiesDestination {
            Divider()
            Button(L10n.t("Cancel Transfer"), role: .destructive) { vm.requestCancelSFTPTransfer(transfer.id) }
        }
    }
}
