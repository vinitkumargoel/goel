import SwiftUI
import AppKit
import GoelCore

/// One SFTP transfer as a row, for the status bar's transfers popover (`.compact`) and the menu
/// bar (`.full`): artwork with a direction badge, the name, server and remote folder (a button
/// that opens the folder in the browser), then the state's controls.
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
        VStack(alignment: .leading, spacing: density == .full ? Studio.Space.xs : 0) {
            HStack(spacing: Studio.Space.sm) {
                SFTPTransferArtwork(transfer: transfer, size: density == .full ? .s : .xs)
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
                Spacer(minLength: density == .full ? Studio.Space.s : Studio.Space.xs)
                trailingControls
            }
            if density == .full, transfer.isActive || transfer.isPaused {
                HStack(spacing: Studio.Space.sm) {
                    StudioLinearProgress(fraction: transfer.total > 0 ? transfer.fraction : nil,
                                         tone: transfer.progressTone, height: StudioLinearProgress.thinHeight)
                        .frame(maxWidth: 160)
                    Text(transfer.sizeLabel)
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .fixedSize()
                    if !transfer.speedLabel.isEmpty {
                        Label(transfer.speedLabel, systemImage: transfer.arrowGlyph)
                            .labelStyle(StudioButtonLabelStyle(spacing: 3, iconSize: 10))
                            .studioFont(Studio.TextStyle.monoSmall.weight(650))
                            .foregroundStyle(transfer.studioDirectionColor)
                    }
                    if let eta = transfer.etaLabel {
                        Text(eta)
                            .studioFont(.monoSmall)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, StudioArtSize.s.side + Studio.Space.sm)
                .a11yGroup(label: L10n.t("Transfer progress"), value: spokenProgress)
            }
        }
        .padding(.horizontal, density == .full ? Studio.Space.ml : Studio.Space.m)
        .padding(.vertical, density == .full ? Studio.Space.s : 7)
    }

    private var identityContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            FileNameText(transfer.name, lineLimit: 1)
                .studioFont(.callout.size(12.5).weight(650))
                .foregroundStyle(Studio.Palette.ink)
            if let serverLabel {
                Text(serverLabel)
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
            }
            Text(transfer.direction == .download
                 ? L10n.t("From %@", transfer.remoteFolderLabel)
                 : L10n.t("To %@", transfer.remoteFolderLabel))
                .studioFont(.caption)
                .foregroundStyle(Studio.Palette.ink3)
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

    private func meta(_ text: String, color: Color = Studio.Palette.ink3) -> some View {
        Text(text)
            .studioFont(.monoSmall)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func control(_ symbol: String, help: String, spoken: String, action: @escaping () -> Void) -> some View {
        StudioIconButton(symbol, label: help, size: .small, action: action)
            .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch transfer.state {
        case .running:
            if density == .compact, !transfer.speedLabel.isEmpty {
                meta(transfer.speedLabel, color: transfer.studioDirectionColor)
                if let eta = transfer.etaLabel { meta(eta) }
            }
            meta(transfer.progressLabel, color: Studio.Palette.ink2)
                .frame(minWidth: density == .full ? 42 : nil, alignment: .trailing)
            if let onPause, transfer.canPause {
                control("pause.fill", help: L10n.t("Pause"),
                        spoken: L10n.t("Pause transfer of %@", transfer.name), action: onPause)
            }
            if let onCancel {
                control("xmark", help: L10n.t("Cancel"),
                        spoken: L10n.t("Cancel transfer of %@", transfer.name), action: onCancel)
            }
        case .waiting:
            Text(L10n.t("Waiting…"))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
            if let onCancel {
                control("xmark", help: L10n.t("Cancel"),
                        spoken: L10n.t("Cancel transfer of %@", transfer.name), action: onCancel)
            }
        case .paused:
            if density == .full {
                meta(L10n.t("Paused") + " · " + transfer.progressLabel, color: Studio.Palette.warn)
            }
            if let onResume {
                control("play.fill", help: L10n.t("Resume"),
                        spoken: L10n.t("Resume transfer of %@", transfer.name), action: onResume)
            }
            if let onCancel {
                control("xmark", help: L10n.t("Cancel"),
                        spoken: L10n.t("Cancel transfer of %@", transfer.name), action: onCancel)
            }
        case .finished:
            if density == .full {
                meta(transfer.total > 0 ? L10n.t("Done") + " · \(transfer.total.byteString)" : L10n.t("Done"),
                     color: Studio.Palette.good)
            } else {
                Text(L10n.t("Done")).studioFont(.small.weight(600)).foregroundStyle(Studio.Palette.good)
            }
        case .cancelled:
            if density == .full {
                Text(L10n.t("Cancelled")).studioFont(.small).foregroundStyle(Studio.Palette.ink3)
            }
            retryButton
        case .failed(let message):
            if density == .full {
                Text(message).studioFont(.small).foregroundStyle(Studio.Palette.bad).lineLimit(1)
            }
            retryButton
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if let onRetry {
            Button(L10n.t("Retry"), action: onRetry)
                .buttonStyle(.studio(.soft, size: .small))
                .accessibilityLabel(L10n.t("Retry transfer of %@", transfer.name))
        }
    }
}
