import SwiftUI
import AppKit
import GoelCore

struct SheetHeader: View {
    let systemImage: String
    let title: String
    /// A small line above the title, e.g. "Welcome to Goel°" over the step name.
    var eyebrow: String? = nil

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                // Not `.white`: on the light accent themes that measured 2.00–2.42:1.
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow)
                        .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
        }
        .padding(18)
    }
}

/// Every sheet's bottom row: optional context on the left, then Cancel and the primary action
/// on the right — ⎋ and ⏎ always land on the same two buttons.
struct SheetFooter<Leading: View, Secondary: View>: View {
    var cancelTitle: String?
    var onCancel: (() -> Void)?
    let primaryTitle: String
    var primaryDisabled = false
    let onPrimary: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var secondary: Secondary

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            leading
            Spacer(minLength: Theme.Space.s)
            if let onCancel {
                Button(cancelTitle ?? L10n.t("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            secondary
            Button(primaryTitle, action: onPrimary)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
        }
        .padding(14)
    }
}

extension SheetFooter where Secondary == EmptyView {
    init(cancelTitle: String? = nil, onCancel: (() -> Void)? = nil, primaryTitle: String,
         primaryDisabled: Bool = false, onPrimary: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel, primaryTitle: primaryTitle,
                  primaryDisabled: primaryDisabled, onPrimary: onPrimary,
                  leading: leading, secondary: { EmptyView() })
    }
}

extension SheetFooter where Leading == EmptyView, Secondary == EmptyView {
    init(cancelTitle: String? = nil, onCancel: (() -> Void)? = nil, primaryTitle: String,
         primaryDisabled: Bool = false, onPrimary: @escaping () -> Void) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel, primaryTitle: primaryTitle,
                  primaryDisabled: primaryDisabled, onPrimary: onPrimary,
                  leading: { EmptyView() }, secondary: { EmptyView() })
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var symbolSize: CGFloat = 38
    var symbolStyle: HierarchicalShapeStyle = .quaternary
    /// An optional way out, e.g. "Clear search and filter" on a no-match list. Shown only when both are set.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .scaledFont(size: symbolSize)
                    .foregroundStyle(symbolStyle)
                    .a11yDecorative()
                Text(title)
                    .scaledFont(size: Theme.TextSize.title)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: Theme.TextSize.body)
                        // Secondary, not tertiary: this line tells the user what to do next.
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            // The button stays outside the ignored-children group, or VoiceOver can't reach it.
            .a11yGroup(label: A11y.sentence(title, subtitle))

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(TintedPillButtonStyle())
            }
        }
    }
}

struct SpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5
    var minWidth: CGFloat? = nil
    var directionName: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).scaledFont(size: size - 1.5, weight: .bold)
            Text(speed > 0 ? speed.speedString : "—")
                .scaledFont(size: size, weight: .semibold, monospacedDigit: true)
                .frame(minWidth: minWidth, alignment: .trailing)
        }
        .foregroundStyle(speed > 0 ? color : Color.secondary)
        .a11yGroup(label: spokenDirection, value: A11y.speed(speed))
    }

    private var spokenDirection: String {
        if let directionName { return directionName }
        return symbol.contains("up") ? L10n.t("Upload speed") : L10n.t("Download speed")
    }
}

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

struct FileTypeIcon: View {
    let type: FileType
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: type.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: type.symbol)
                    // fixed-size: the glyph is half its tile, and the tile's frame is fixed by the caller.
                    .font(.system(size: size * 0.5, weight: .semibold))
                    // Picked per fill: white measured 1.72:1 on the old archive blue.
                    .foregroundStyle(type.ink)
            )
            .a11yDecorative()
    }
}

struct KindBadge: View {
    let kind: DownloadKind
    var size: CGFloat = 9.5

    init(kind: DownloadKind, size: CGFloat = 9.5) {
        self.kind = kind
        self.size = size
    }

    init(task: DownloadTask) {
        self.init(kind: task.kind)
    }

    var body: some View {
        Text(kind.badgeLabel)
            .scaledFont(size: size, weight: .bold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kind.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .foregroundStyle(kind.badgeColor)
            // 12% tint keeps text contrast at 3.83–7.95:1; 20% dropped it to 2.94:1 (SC 1.4.3).
            .accessibilityLabel(kind.accessibilityName)
    }
}

struct MiniProgressBar: View {
    let task: DownloadTask
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if task.status == .requestingMetadata {
                    IndeterminateBar(tint: Theme.orange)
                } else {
                    Capsule()
                        .fill(task.progressTint)
                        .frame(width: max(0, geo.size.width * task.fractionCompleted))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(L10n.t("Progress"))
        .accessibilityValue(task.status == .requestingMetadata
                            ? L10n.t("Requesting information")
                            : task.accessibilityProgressValue)
    }
}

/// "Working, amount unknown". A static capsule at 40% read as 40% progress, so this sweeps a short
/// highlight across the track instead; under Reduce Motion it holds still as diagonal stripes,
/// which read as "in progress" without claiming a fraction.
struct IndeterminateBar: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A list can hold many of these; one scrolled out of view (or in a closed window) must not keep
    /// asking for frames.
    @State private var isVisible = false

    /// Capped: an uncapped `.animation` timeline redraws each row at the display's full refresh rate,
    /// which for a highlight this soft is only wasted frames.
    static let frameInterval: TimeInterval = 1.0 / 30

    /// One sweep, left edge to right edge.
    static let period: TimeInterval = 1.2
    /// The highlight's share of the track.
    static let bandFraction: CGFloat = 0.3

    /// The band's leading edge at `time`, as a fraction of the track: it starts fully off the left
    /// and ends fully off the right, so the sweep wraps without a visible jump.
    static func bandOffset(at time: TimeInterval) -> CGFloat {
        let phase = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
        return -bandFraction + phase * (1 + bandFraction)
    }

    var body: some View {
        GeometryReader { geo in
            if reduceMotion {
                stripes(size: geo.size)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isVisible)) { context in
                    let width = geo.size.width * Self.bandFraction
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: width)
                        .offset(x: geo.size.width
                                * Self.bandOffset(at: context.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .clipShape(Capsule())
        .a11yDecorative()
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// 45° stripes, spaced by the bar's height so they stay diagonal at any thickness.
    private func stripes(size: CGSize) -> some View {
        Path { path in
            let step = max(size.height * 2, 4)
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + step / 2, y: 0))
                path.addLine(to: CGPoint(x: x + step / 2, y: size.height))
                path.closeSubpath()
                x += step
            }
        }
        .fill(tint.opacity(0.7))
    }
}

/// What a row's leading button does. One glyph used to mean four things in the same grey; now the
/// action decides the tint, a failure gets a word, and a finished file gets no button at all
/// (double-click and Return already open it) unless the file went missing.
enum RowStateAction: Equatable {
    case pause, resume, retry, locate

    /// Nil: nothing worth a button (a completed download whose file is still there).
    init?(task: DownloadTask) {
        switch task.status {
        case .completed:
            guard task.isFileMissing else { return nil }
            self = .locate
        case .failed: self = .retry
        case .paused, .queued: self = .resume
        default: self = .pause
        }
    }

    var symbol: String {
        switch self {
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .retry: return "arrow.clockwise"
        case .locate: return "magnifyingglass"
        }
    }

    var title: String {
        switch self {
        case .pause: return L10n.t("Pause")
        case .resume: return L10n.t("Resume")
        case .retry: return L10n.t("Retry")
        case .locate: return L10n.t("Locate File…")
        }
    }
}

/// `vm` is a plain reference, not observed — observing re-renders every row on each publish.
struct StateButton: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        if let action = RowStateAction(task: task) {
            if action == .retry {
                Button { perform(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                        .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.red.opacity(0.16)))
                        .foregroundStyle(Theme.red)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(action.title)
                .a11yButton(L10n.t("%1$@ %2$@", action.title, task.name))
            } else {
                Button { perform(action) } label: {
                    Image(systemName: action.symbol)
                        .scaledFont(size: Theme.TextSize.caption, weight: .bold)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(fill(action)))
                        .foregroundStyle(action == .resume ? Theme.accent : Color.primary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(action.title)
                .a11yButton(L10n.t("%1$@ %2$@", action.title, task.name))
            }
        } else {
            // Keeps names in line with the rows that do have a button.
            Color.clear.frame(width: 24, height: 24).a11yDecorative()
        }
    }

    private func fill(_ action: RowStateAction) -> Color {
        action == .resume ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.08)
    }

    private func perform(_ action: RowStateAction) {
        switch action {
        case .locate: vm.locateMissingFile(task)
        case .retry: vm.retry(task.id)
        case .resume: vm.resume(task.id)
        case .pause: vm.pause(task.id)
        }
    }
}

/// "Pasted from clipboard" beside a field the sheet filled in by itself, with a button to clear it.
struct PastedFromClipboardNote: View {
    var clearHelp: String = L10n.t("Clear the pasted text")
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Label(L10n.t("Pasted from clipboard"), systemImage: "doc.on.clipboard")
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
            IconButton(symbol: "xmark", help: clearHelp, size: 9, action: onClear)
        }
    }
}
