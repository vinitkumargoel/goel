import SwiftUI
import AppKit
import GoelCore

// Compatibility: the SFTP transfer row from the old `SharedViews.swift`, still drawn by the
// menu bar (Windows) and the status bar (MainWindow). Moved unchanged; deleted at integration
// once both have their Studio rows.

struct SFTPTransferRow: View {
    enum Density { case compact, full }

    let transfer: SFTPTransfer
    var density: Density = .full
    var serverLabel: String? = nil
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onShowRemoteFolder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: density == .full ? 3 : 0) {
            HStack(spacing: 8) {
                Image(systemName: transfer.iconName(filledWhenFinished: density == .full))
                    .foregroundStyle(transfer.tint)
                    .a11yDecorative()
                if let onShowRemoteFolder {
                    Button(action: onShowRemoteFolder) {
                        identityContent
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                    .accessibilityLabel(
                        A11y.sentence(spokenDirection, transfer.name, serverLabel,
                                      L10n.t("Remote folder %@", transfer.remoteFolderLabel)))
                    .accessibilityValue(spokenProgress)
                    .accessibilityHint(L10n.t("Opens this folder in the SFTP browser."))
                } else {
                    identityContent
                }
                Spacer(minLength: density == .full ? 8 : 6)
                trailingControls
            }
            if density == .full, transfer.isActive || transfer.isPaused {
                HStack(spacing: 10) {
                    ProgressView(value: transfer.fraction).frame(maxWidth: 160)
                    Text(transfer.sizeLabel)
                        .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true).foregroundStyle(.secondary)
                    if !transfer.speedLabel.isEmpty {
                        Label(transfer.speedLabel,
                              systemImage: transfer.arrowGlyph)
                            .labelStyle(.titleAndIcon)
                            .scaledFont(size: Theme.TextSize.caption, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(transfer.directionTint)
                    }
                    if let eta = transfer.etaLabel {
                        Text(eta).scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                .a11yGroup(label: L10n.t("Transfer progress"), value: spokenProgress)
            }
        }
        .padding(.horizontal, density == .full ? 14 : 12)
        .padding(.vertical, density == .full ? 5 : 6)
    }

    private var identityContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(transfer.name)
                .scaledFont(size: Theme.TextSize.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if let serverLabel {
                Text(serverLabel)
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(transfer.direction == .download
                 ? L10n.t("From %@", transfer.remoteFolderLabel)
                 : L10n.t("To %@", transfer.remoteFolderLabel))
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .a11yGroup(
            label: A11y.sentence(spokenDirection, transfer.name, serverLabel,
                                 L10n.t("Remote folder %@", transfer.remoteFolderLabel)),
            value: spokenProgress)
    }

    private var spokenDirection: String {
        L10n.t(transfer.activityLabel)
    }

    private var spokenProgress: String {
        switch transfer.state {
        case .running:
            return A11y.sentence(
                A11y.percent(transfer.fraction),
                L10n.t("%1$@ of %2$@", A11y.bytes(transfer.bytes), A11y.bytes(transfer.total)),
                transfer.displaySpeed > 0 ? A11y.speed(transfer.displaySpeed) : nil)
        case .waiting:
            return L10n.t("Waiting to start")
        case .paused:
            return A11y.sentence(
                L10n.t("Paused"),
                A11y.percent(transfer.fraction),
                L10n.t("%1$@ of %2$@", A11y.bytes(transfer.bytes), A11y.bytes(transfer.total)))
        case .finished:
            return A11y.sentence(L10n.t("Finished"), transfer.total > 0 ? A11y.bytes(transfer.total) : nil)
        case .cancelled:
            return L10n.t("Cancelled")
        case .failed(let message):
            return L10n.t("Failed, %@", message)
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch transfer.state {
        case .running:
            if density == .compact, !transfer.speedLabel.isEmpty {
                Text(transfer.speedLabel)
                    .scaledFont(size: Theme.TextSize.meta, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(transfer.directionTint)
                if let eta = transfer.etaLabel {
                    Text(eta)
                        .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(.secondary)
                }
            }
            if density == .full {
                Text(transfer.progressLabel)
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            } else {
                Text(transfer.progressLabel)
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(.secondary)
            }
            if let onPause, transfer.canPause {
                IconButton(symbol: "pause.circle.fill", help: L10n.t("Pause"), size: 12,
                           spokenLabel: L10n.t("Pause transfer of %@", transfer.name),
                           action: onPause)
            }
            if let onCancel {
                IconButton(symbol: "xmark.circle.fill", help: L10n.t("Cancel"), size: 12,
                           spokenLabel: L10n.t("Cancel transfer of %@", transfer.name),
                           action: onCancel)
            }
        case .waiting:
            Text(L10n.t("Waiting…"))
                .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            if let onCancel {
                IconButton(symbol: "xmark.circle.fill", help: L10n.t("Cancel"), size: 12,
                           spokenLabel: L10n.t("Cancel transfer of %@", transfer.name),
                           action: onCancel)
            }
        case .paused:
            if density == .full {
                Text(L10n.t("Paused") + " · " + transfer.progressLabel)
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(Theme.orange)
            }
            if let onResume {
                IconButton(symbol: "play.circle.fill", help: L10n.t("Resume"), size: 12, tint: Theme.accent,
                           spokenLabel: L10n.t("Resume transfer of %@", transfer.name),
                           action: onResume)
            }
            if let onCancel {
                IconButton(symbol: "xmark.circle.fill", help: L10n.t("Cancel"), size: 12,
                           spokenLabel: L10n.t("Cancel transfer of %@", transfer.name),
                           action: onCancel)
            }
        case .finished:
            if density == .full {
                Text(transfer.total > 0 ? L10n.t("Done") + " · \(transfer.total.byteString)" : L10n.t("Done"))
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true).foregroundStyle(Theme.green)
            } else {
                Text(L10n.t("Done")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.green)
            }
        case .cancelled:
            if density == .full {
                Text(L10n.t("Cancelled")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            }
            if let onRetry {
                Button(L10n.t("Retry"), action: onRetry)
                    .buttonStyle(.plain).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.accent)
                    .accessibilityLabel(L10n.t("Retry transfer of %@", transfer.name))
            }
        case .failed(let message):
            if density == .full {
                Text(message).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.red).lineLimit(1)
            }
            if let onRetry {
                Button(L10n.t("Retry"), action: onRetry)
                    .buttonStyle(.plain).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.accent)
                    .accessibilityLabel(L10n.t("Retry transfer of %@", transfer.name))
            }
        }
    }
}
