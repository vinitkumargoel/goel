import SwiftUI
import AppKit
import GoelCore

/// The accent-icon-tile + title row that heads the Add and Link-Grabber sheets.
struct SheetHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                // Not `.white`: the accent is a light colour in three of the four
                // themes, where a white glyph on it measured 2.00–2.42:1.
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                // The tile restates the sheet's subject; the title beside it
                // already says it in words.
                .a11yDecorative()
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                // Sheets are announced by their heading, so mark it as one.
                .accessibilityAddTraits(.isHeader)
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
                .a11yDecorative()
            Text(title)
                .scaledFont(size: 14)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        // Title and subtitle are one message ("No downloads match / Try a
        // different filter"), so read them as one rather than two stray strings.
        .a11yGroup(label: A11y.sentence(title, subtitle))
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
    /// Which direction the arrow means, spoken. Defaults are derived from the symbol so existing call
    /// sites need no change; pass explicitly when the glyph isn't a plain up/down arrow.
    var directionName: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: size - 1.5, weight: .bold))
            Text(speed > 0 ? speed.speedString : "—")
                .scaledFont(size: size, weight: .semibold, monospacedDigit: true)
                .frame(minWidth: minWidth, alignment: .trailing)
        }
        .foregroundStyle(speed > 0 ? color : Color.secondary)
        // An arrow glyph plus "14.2 MB/s" is meaningless read aloud: VoiceOver names the arrow, not what
        // it measures, and "—" is silent. Speak the direction and the rate in words.
        .a11yGroup(label: spokenDirection, value: A11y.speed(speed))
    }

    private var spokenDirection: String {
        if let directionName { return directionName }
        return symbol.contains("up") ? "Upload speed" : "Download speed"
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
    var onShowRemoteFolder: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: density == .full ? 3 : 0) {
            HStack(spacing: 8) {
                Image(systemName: transfer.iconName(filledWhenFinished: density == .full))
                    .foregroundStyle(transfer.tint)
                    // The glyph encodes direction + state, both of which the
                    // grouped label below already says in words.
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
                                      "Remote folder \(transfer.remoteFolderLabel)"))
                    .accessibilityValue(spokenProgress)
                    .accessibilityHint("Opens this folder in the SFTP browser.")
                } else {
                    identityContent
                }
                Spacer(minLength: density == .full ? 8 : 6)
                trailingControls
            }
            if density == .full, transfer.isActive {
                HStack(spacing: 10) {
                    ProgressView(value: transfer.fraction).frame(maxWidth: 160)
                    Text(transfer.sizeLabel)
                        .scaledFont(size: 10.5, monospacedDigit: true).foregroundStyle(.secondary)
                    if !transfer.speedLabel.isEmpty {
                        Label(transfer.speedLabel,
                              systemImage: transfer.arrowGlyph)
                            .labelStyle(.titleAndIcon)
                            .scaledFont(size: 10.5, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(transfer.directionTint)
                    }
                    if let eta = transfer.etaLabel {
                        Text(eta).scaledFont(size: 10.5, monospacedDigit: true).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                // Bar + size + rate + ETA are four readings of one thing. Fold
                // them into a single progress element rather than four.
                .a11yGroup(label: "Transfer progress", value: spokenProgress)
            }
        }
        .padding(.horizontal, density == .full ? 14 : 12)
        .padding(.vertical, density == .full ? 5 : 6)
    }

    private var identityContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(transfer.name)
                .scaledFont(size: 12)
                .lineLimit(1)
                .truncationMode(.middle)
            if let serverLabel {
                Text(serverLabel)
                    .scaledFont(size: density == .compact ? 10 : 10.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text("\(transfer.folderPreposition) \(transfer.remoteFolderLabel)")
                .scaledFont(size: density == .compact ? 10 : 10.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The identity and live numbers form one spoken element. Cancel/retry stay
        // separate sibling controls so activating them never reveals the folder.
        .a11yGroup(
            label: A11y.sentence(spokenDirection, transfer.name, serverLabel,
                                 "Remote folder \(transfer.remoteFolderLabel)"),
            value: spokenProgress)
    }

    /// "Uploading" / "Downloading" — the arrow glyph and tint, in words.
    private var spokenDirection: String {
        transfer.activityLabel
    }

    /// The transfer's live numbers as one spoken value, ending in its state so a
    /// finished or failed transfer says so rather than reporting a stale percent.
    private var spokenProgress: String {
        switch transfer.state {
        case .running:
            return A11y.sentence(
                A11y.percent(transfer.fraction),
                "\(A11y.bytes(transfer.bytes)) of \(A11y.bytes(transfer.total))",
                transfer.displaySpeed > 0 ? A11y.speed(transfer.displaySpeed) : nil)
        case .finished:
            return A11y.sentence("Finished", transfer.total > 0 ? A11y.bytes(transfer.total) : nil)
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return "Failed, \(message)"
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch transfer.state {
        case .running:
            if density == .compact, !transfer.speedLabel.isEmpty {
                Text(transfer.speedLabel)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(transfer.directionTint)
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
                // Name the target: a popover of transfers otherwise reads as a
                // column of identical "Cancel" buttons.
                .a11yButton("Cancel transfer of \(transfer.name)")
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
                Text("Cancelled").scaledFont(size: 11).foregroundStyle(.secondary)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain).scaledFont(size: 11).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Retry transfer of \(transfer.name)")
            }
        case .failed(let message):
            if density == .full {
                Text(message).scaledFont(size: 11).foregroundStyle(Theme.red).lineLimit(1)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain).scaledFont(size: 11).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Retry transfer of \(transfer.name)")
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
            // Colour-coded restatement of the file's kind. Every row showing this tile also names the file,
            // whose extension carries the same information — so hiding it removes noise, not meaning.
            .a11yDecorative()
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
            .background(task.kindBadgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(task.kindBadgeColor)
            // The chip's tint sits under its text, eating contrast: at the mockup's 20% it measured 2.94–4.20:1.
            // 12% gives most of it back (3.83–7.95:1) but not everywhere — see docs/vpat.md, SC 1.4.3.
            .accessibilityLabel(task.accessibilityKindName)
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
        // A bar that announces nothing is useless to a screen-reader user. Give it the progress trait
        // and a spoken value; an indeterminate metadata fetch says so rather than reporting 0 percent.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progress")
        .accessibilityValue(task.status == .requestingMetadata
                            ? "Requesting information"
                            : task.accessibilityProgressValue)
    }
}

/// The circular state button shown in each row (play / pause / retry / folder). Holds `vm` as a
/// plain reference so it doesn't make every row re-render on each progress publish.
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
        // One glyph, four meanings, repeated once per row. Without the file name
        // the whole list reads as "button, button, button".
        .a11yButton("\(task.accessibilityStateActionName) \(task.name)")
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
