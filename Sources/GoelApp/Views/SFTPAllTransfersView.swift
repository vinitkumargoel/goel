import SwiftUI
import GoelCore

/// Counts behind the sidebar's "Transfers" row: what is moving, and what needs a look.
struct SFTPTransferSummary: Equatable {
    var active = 0
    var failed = 0
    var total = 0

    init(_ transfers: [SFTPTransfer]) {
        for transfer in transfers {
            total += 1
            if transfer.isActive { active += 1 }
            if case .failed = transfer.state { failed += 1 }
        }
    }
}

/// The sidebar row under Servers: live count plus a red badge when anything failed.
struct SFTPTransfersSidebarRow: View {
    let summary: SFTPTransferSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.arrow.down")
                    .scaledFont(size: Theme.TextSize.sheet).frame(width: 16)
                Text(L10n.t("Transfers")).scaledFont(size: Theme.TextSize.body)
                Spacer(minLength: 4)
                badges
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Show transfers on every server"))
        .accessibilityLabel(L10n.t("Transfers"))
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var badges: some View {
        if summary.failed > 0 {
            Text(verbatim: "\(summary.failed)")
                .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Theme.red))
                .help(L10n.t("%d failed", summary.failed))
        }
        if summary.active > 0 {
            Text(verbatim: "\(summary.active)")
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var accessibilityValue: String {
        A11y.sentence(L10n.t("%d active", summary.active),
                      summary.failed > 0 ? L10n.t("%d failed", summary.failed) : nil)
    }
}

/// Every server's uploads and downloads in one list, grouped by server.
struct SFTPAllTransfersView: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed so progress and state changes redraw the list.
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.sftpTransfers.isEmpty {
                emptyState
            } else {
                transferList
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 320, idealHeight: 440)
    }

    private var header: some View {
        HStack {
            Text(L10n.t("Transfers")).scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
            Spacer()
            Button(L10n.t("Clear Finished")) { vm.clearFinishedSFTPTransfers() }
                .disabled(!vm.sftpTransfers.contains { !$0.occupiesDestination })
            Button(L10n.t("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down").scaledFont(size: 28).foregroundStyle(.secondary)
                .a11yDecorative()
            Text(L10n.t("No transfers yet")).scaledFont(size: Theme.TextSize.body, weight: .medium)
            Text(L10n.t("Uploads and downloads from your servers appear here."))
                .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groups: [(SFTPConnection.ID, [SFTPTransfer])] {
        let grouped = Dictionary(grouping: vm.sftpTransfers, by: \.connectionID)
        return grouped.keys.sorted { serverName($0) < serverName($1) }.map { ($0, grouped[$0] ?? []) }
    }

    private func serverName(_ id: SFTPConnection.ID) -> String {
        vm.server(id)?.label ?? L10n.t("Removed server")
    }

    private var transferList: some View {
        List {
            ForEach(groups, id: \.0) { group in
                Section(serverName(group.0)) {
                    ForEach(group.1) { transfer in
                        SFTPAllTransfersRow(transfer: transfer)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct SFTPAllTransfersRow: View {
    let transfer: SFTPTransfer
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16).a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).scaledFont(size: Theme.TextSize.body).lineLimit(1).truncationMode(.middle)
                ProgressView(value: transfer.fraction).controlSize(.small).tint(tint)
                Text(statusLine).scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(isFailed ? Theme.red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            actions
        }
        .padding(.vertical, 3)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var symbol: String {
        switch transfer.direction {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .remoteCopy: return "doc.on.doc"
        }
    }

    private var tint: Color { isFailed ? Theme.red : Theme.accent }

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
        if transfer.canPause {
            IconButton(symbol: "pause.fill", help: L10n.t("Pause")) { vm.pauseSFTPTransfer(transfer.id) }
        } else if transfer.canResume {
            IconButton(symbol: "play.fill", help: L10n.t("Resume")) { vm.resumeSFTPTransfer(transfer.id) }
        } else if isFailed {
            IconButton(symbol: "arrow.clockwise", help: L10n.t("Retry")) { vm.retrySFTPTransfer(transfer.id) }
        }
        IconButton(symbol: "folder", help: L10n.t("Show on Server")) { vm.revealSFTPTransfer(transfer) }
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
