import SwiftUI
import GoelCore

/// The accent-icon-tile + title row that heads the Add and Link-Grabber sheets.
struct SheetHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(18)
    }
}

/// Shared empty-list / empty-panel chrome: SF Symbol + title + optional subtitle.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var symbolSize: CGFloat = 38
    var symbolStyle: HierarchicalShapeStyle = .quaternary

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize))
                .foregroundStyle(symbolStyle)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// ↓ / ↑ speed readout: coloured while transferring, dimmed to "—" at rest.
/// Shared by detail panel, menu bar, and status bar.
struct SpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5
    var minWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: size - 1.5, weight: .bold))
            Text(speed > 0 ? speed.speedString : "—")
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: minWidth, alignment: .trailing)
        }
        .foregroundStyle(speed > 0 ? color : Color.secondary)
    }
}

/// Shared SFTP transfer row for browser strip (full) and status-bar popover (compact).
struct SFTPTransferRow: View {
    enum Density { case compact, full }

    let transfer: SFTPTransfer
    var density: Density = .full
    var serverLabel: String? = nil
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: density == .full ? 3 : 0) {
            HStack(spacing: 8) {
                Image(systemName: transfer.iconName(filledWhenFinished: density == .full))
                    .foregroundStyle(transfer.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transfer.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let serverLabel {
                        Text(serverLabel)
                            .font(.system(size: density == .compact ? 10 : 10.5))
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: density == .full ? 8 : 6)
                trailingControls
            }
            if density == .full, transfer.isActive {
                HStack(spacing: 10) {
                    ProgressView(value: transfer.fraction).frame(maxWidth: 160)
                    Text(transfer.sizeLabel)
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    if !transfer.speedLabel.isEmpty {
                        Label(transfer.speedLabel,
                              systemImage: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(transfer.direction == .upload ? Theme.teal : Theme.green)
                    }
                    if let eta = transfer.etaLabel {
                        Text(eta).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, density == .full ? 14 : 12)
        .padding(.vertical, density == .full ? 5 : 6)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch transfer.state {
        case .running:
            if density == .compact, !transfer.speedLabel.isEmpty {
                Text(transfer.speedLabel)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(transfer.direction == .upload ? Theme.teal : Theme.green)
            }
            if density == .full {
                Text(transfer.progressLabel)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            } else {
                Text(transfer.progressLabel)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
            }
        case .finished:
            if density == .full {
                Text(transfer.total > 0 ? "Done · \(transfer.total.byteString)" : "Done")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.green)
            } else {
                Text("Done").font(.system(size: 11)).foregroundStyle(Theme.green)
            }
        case .cancelled:
            if density == .full {
                Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        case .failed(let message):
            if density == .full {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(1)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// The colored rounded type tile with an SF Symbol (the `.ftype` chip).
struct FileTypeIcon: View {
    let type: FileType
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: type.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: type.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// The HTTP / BT badge.
struct KindBadge: View {
    let task: DownloadTask
    var body: some View {
        Text(task.kindBadge)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(task.kindBadgeColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(task.kindBadgeColor)
    }
}

/// Marks a download bound for — or already sitting on — a saved server. Absent when there is no destination.
struct RemoteBadge: View {
    let destination: RemoteDestination?

    var body: some View {
        if let destination {
            Image(systemName: symbol(destination.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(destination.state))
                .help(help(destination))
        }
    }

    private func symbol(_ state: RemoteUploadState) -> String {
        switch state {
        case .pending:   return "clock.arrow.up.trianglehead.clockwise"
        case .uploading: return "arrow.up.circle"
        case .uploaded:  return "externaldrive.badge.checkmark"
        case .failed:    return "exclamationmark.triangle.fill"
        case .held:      return "pause.circle"
        }
    }

    private func tint(_ state: RemoteUploadState) -> Color {
        switch state {
        case .pending, .held: return .secondary
        case .uploading:      return Theme.teal
        case .uploaded:       return Theme.green
        case .failed:         return Theme.red
        }
    }

    private func help(_ destination: RemoteDestination) -> String {
        switch destination.state {
        case .pending:   return "Waiting to send to \(destination.serverLabel)"
        case .uploading: return "Sending to \(destination.serverLabel)"
        case .uploaded:  return "On \(destination.displayLocation)"
        case .failed:    return destination.failureMessage ?? "Could not send to \(destination.serverLabel)"
        case .held:      return destination.failureMessage ?? "Paused"
        }
    }
}

/// A thin progress bar tinted by the task's state. Shimmers while resolving
/// metadata (indeterminate).
struct MiniProgressBar: View {
    let task: DownloadTask
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if task.status == .requestingMetadata {
                    Capsule()
                        .fill(Theme.orange.opacity(0.7))
                        .frame(width: geo.size.width * 0.4)
                } else {
                    Capsule()
                        .fill(task.progressTint)
                        .frame(width: max(0, geo.size.width * task.fractionCompleted))
                }
            }
        }
        .frame(height: height)
    }
}

/// The circular state button shown in each row (play / pause / retry / folder).
/// Holds `vm` as a plain reference (not `@EnvironmentObject`) so it doesn't make
/// every row re-render on each progress publish — see `DownloadRow`.
struct StateButton: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var symbol: String {
        switch task.status {
        case .completed: return "folder"
        case .failed: return "arrow.clockwise"
        case .paused, .queued: return "play.fill"
        default: return "pause.fill"
        }
    }

    private var helpText: String {
        switch task.status {
        case .completed: return "Open folder"
        case .failed: return "Retry"
        case .paused, .queued: return "Resume"
        default: return "Pause"
        }
    }

    private func action() {
        switch task.status {
        case .completed: vm.revealInFinder(task)
        case .failed: vm.retry(task.id)
        case .paused, .queued: vm.resume(task.id)
        default: vm.pause(task.id)
        }
    }
}
