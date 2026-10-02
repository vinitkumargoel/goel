import SwiftUI
import AppKit
import GoelCore

/// A failed download: the reason in red and a Retry, so the popover doesn't claim "No active
/// downloads" while one sits broken.
struct MenuBarFailedRow: View {
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void

    var body: some View {
        WindowsCompactCard(isFailure: true) {
            HStack(spacing: 11) {
                StudioFileArtwork(kind: StudioArtKind(task: task), size: .s)
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    FileNameText(task.compactDisplayName, lineLimit: 1)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                    if case .failed(let error) = task.status {
                        Text(error.message)
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.bad)
                            .lineLimit(2)
                            .help(A11y.sentence(error.message, FailureAdvice.hint(for: error)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .help(L10n.t("Show in Goel°"))
            .a11yGroup(label: A11y.sentence(task.compactDisplayName, task.accessibilityStatusName))
            .accessibilityAction(named: L10n.t("Show in Goel°"), onOpen)
            Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retry(task.id) }
                .buttonStyle(.studio(.soft, size: .small))
                .a11yButton(L10n.t("Retry %@", task.name))
        }
    }
}

/// A running or waiting download: name and protocol, a thin bar, its status and speed, and the
/// pause/resume button.
struct MenuBarDownloadRow: View {
    @EnvironmentObject private var telemetry: TelemetryStore
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void

    var body: some View {
        let state = StudioDownloadState(task: task)
        WindowsCompactCard {
            HStack(spacing: 11) {
                StudioFileArtwork(kind: StudioArtKind(task: task), size: .s,
                                  isFaded: state == .paused || state == .queued,
                                  isFetchingMetadata: state == .requestingMetadata)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Studio.Space.xs) {
                        FileNameText(task.compactDisplayName, lineLimit: 1)
                            .studioFont(.bodyStrong)
                            .foregroundStyle(Studio.Palette.ink)
                        StudioKindBadge(kind: task.kind)
                        Spacer(minLength: 0)
                    }
                    StudioLinearProgress(fraction: progressFraction, tone: StudioProgressTone(task: task),
                                         height: StudioLinearProgress.thinHeight)
                        .padding(.vertical, Studio.Space.hair)
                        .accessibilityHidden(true)
                    HStack(spacing: 5) {
                        Text(task.statusDetailText)
                            .studioFont(.mono)
                            .foregroundStyle(Studio.Palette.ink3)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let speed = trailingSpeed {
                            Text(speed.text)
                                .studioFont(.mono.weight(600))
                                .foregroundStyle(speed.color)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .help(L10n.t("Show in Goel°"))
            .a11yGroup(label: A11y.sentence(task.compactDisplayName,
                                            task.accessibilityKindName,
                                            task.accessibilityStatusName),
                       value: task.accessibilityProgressValue)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: L10n.t("Show in Goel°"), onOpen)
            MenuBarStateButton(task: task, vm: vm)
        }
    }

    /// Fetching metadata has no fraction yet: the bar slides instead.
    private var progressFraction: Double? {
        task.status == .requestingMetadata ? nil : task.fractionCompleted
    }

    private var trailingSpeed: (text: String, color: Color)? {
        let speed = telemetry.displaySpeed(for: task)
        if speed.down > 0 { return (speed.down.speedString, Studio.Palette.accent) }
        if speed.up > 0 { return (speed.up.speedString, Studio.Palette.upload) }
        return nil
    }
}

/// Pause, resume, retry or locate, whichever the task's state allows.
struct MenuBarStateButton: View {
    let task: DownloadTask
    let vm: AppViewModel

    private enum Action { case pause, resume, retry, locate }

    private var action: Action? {
        switch task.status {
        case .completed: return task.isFileMissing ? .locate : nil
        case .failed: return .retry
        case .paused, .queued: return .resume
        default: return .pause
        }
    }

    var body: some View {
        if let action {
            let (symbol, title) = describe(action)
            StudioIconButton(symbol, label: L10n.t("%1$@ %2$@", title, task.name), size: .small,
                             bordered: action != .resume, isOn: action == .resume) {
                perform(action)
            }
            .help(title)
        }
    }

    private func describe(_ action: Action) -> (String, String) {
        switch action {
        case .pause: return ("pause.fill", L10n.t("Pause"))
        case .resume: return ("play.fill", L10n.t("Resume"))
        case .retry: return ("arrow.clockwise", L10n.t("Retry"))
        case .locate: return ("magnifyingglass", L10n.t("Locate File…"))
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .locate: vm.locateMissingFile(task)
        case .retry: vm.retry(task.id)
        case .resume: vm.resume(task.id)
        case .pause: vm.pause(task.id)
        }
    }
}

/// A download that finished in the last day: drag it out, Quick Look it, open it or show it.
struct MenuBarFinishedRow: View {
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void
    @State private var hovered = false

    private var fileURL: URL { URL(fileURLWithPath: task.savePath) }

    var body: some View {
        WindowsCompactCard(isHovered: hovered) {
            Image(systemName: "line.3.horizontal")
                .font(StudioFonts.font(.ui, size: 11, weight: 700))
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityHidden(true)
            HStack(spacing: 11) {
                StudioFileArtwork(kind: StudioArtKind(task: task), size: .s)
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    FileNameText(task.name, lineLimit: 1)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                    HStack(spacing: 0) {
                        if let total = task.totalBytes, total > 0 {
                            Text(verbatim: total.byteString + " · ")
                        }
                        if let completedAt = task.completedAt {
                            // Rendered by SwiftUI so "2 min ago" keeps counting while the popover is open.
                            Text(completedAt, format: .relative(presentation: .named))
                                .environment(\.locale, DisplayFormat.appLocale)
                        }
                    }
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: L10n.t("Show in Goel°"), onOpen)
            .accessibilityAction(named: L10n.t("Quick Look")) { QuickLookPresenter.shared.present(fileURL) }
            HStack(spacing: Studio.Space.hair) {
                StudioIconButton("eye", label: L10n.t("Quick Look %@", task.name), size: .small) {
                    QuickLookPresenter.shared.present(fileURL)
                }
                .help(L10n.t("Quick Look"))
                .opacity(hovered ? 1 : 0.55)
                StudioIconButton("folder", label: L10n.t("Show %@ in Finder", task.name), size: .small) {
                    vm.revealInFinder(task)
                }
                .help(L10n.t("Show in Finder"))
                Button(L10n.t("Open")) { vm.openFile(task) }
                    .buttonStyle(.studio(.soft, size: .small))
                    .a11yButton(L10n.t("Open %@", task.name))
            }
        }
        .onHover { hovered = $0 }
        // Drag the finished file straight out of the popover into Finder, Mail, a chat…
        .onDrag { NSItemProvider(object: fileURL as NSURL) }
        .help(L10n.t("Drag the file out to use it anywhere"))
    }
}

/// An SFTP transfer in flight or paused: direction, server and folder, progress, and its controls.
/// Stopping asks first, because a stopped transfer leaves the list.
struct MenuBarSFTPTransferRow: View {
    let transfer: SFTPTransfer
    let serverLabel: String
    let vm: AppViewModel
    let onShowRemoteFolder: () -> Void
    @State private var confirmingCancel = false

    var body: some View {
        WindowsCompactCard {
            Button(action: onShowRemoteFolder) {
                HStack(spacing: 11) {
                    WindowsGlyphTile(symbol: transfer.arrowGlyph,
                                     tone: transfer.direction == .upload ? .upload : .accent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Studio.Space.xs) {
                            FileNameText(transfer.name, lineLimit: 1)
                                .studioFont(.bodyStrong)
                                .foregroundStyle(Studio.Palette.ink)
                            StudioBadge(serverLabel)
                        }
                        StudioLinearProgress(fraction: transfer.state == .waiting ? nil : transfer.fraction,
                                             tone: transfer.isPaused ? .paused : transfer.direction == .upload ? .upload : .accent,
                                             height: StudioLinearProgress.thinHeight)
                            .padding(.vertical, Studio.Space.hair)
                        Text(detailLine)
                            .studioFont(.mono)
                            .foregroundStyle(transfer.isPaused ? Studio.Palette.warn : Studio.Palette.ink3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(A11y.sentence(L10n.t(transfer.activityLabel), transfer.name, serverLabel,
                                              L10n.t("Remote folder %@", transfer.remoteFolderLabel)))
            .accessibilityValue(spokenProgress)
            .accessibilityHint(L10n.t("Opens this folder in the SFTP browser."))
            .help(transfer.direction == .download ? L10n.t("From %@", transfer.remoteFolderLabel)
                                                  : L10n.t("To %@", transfer.remoteFolderLabel))
            controls
        }
        .confirmationDialog(transfer.cancelQuestion, isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button(L10n.t("Stop Transfer"), role: .destructive) { vm.cancelSFTPTransfer(transfer.id) }
            Button(L10n.t("Keep Going"), role: .cancel) {}
        } message: {
            Text(L10n.t("“%@” will stop transferring and be removed from the list.", transfer.name))
        }
    }

    /// "4.1 GB / 5.2 GB · 12 MB/s · 1m left", or "Waiting…" / "Paused · 62%".
    private var detailLine: String {
        switch transfer.state {
        case .waiting:
            return L10n.t("Waiting…")
        case .paused:
            return L10n.t("Paused") + " · " + transfer.progressLabel
        default:
            var parts = [transfer.sizeLabel]
            if !transfer.speedLabel.isEmpty { parts.append(transfer.speedLabel) }
            if let eta = transfer.etaLabel { parts.append(eta) }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Studio.Space.hair) {
            if transfer.canPause {
                StudioIconButton("pause.fill", label: L10n.t("Pause transfer of %@", transfer.name), size: .small,
                                 bordered: true) {
                    vm.pauseSFTPTransfer(transfer.id)
                }
                .help(L10n.t("Pause"))
            }
            if transfer.canResume {
                StudioIconButton("play.fill", label: L10n.t("Resume transfer of %@", transfer.name),
                                 size: .small, isOn: true) {
                    vm.resumeSFTPTransfer(transfer.id)
                }
                .help(L10n.t("Resume"))
            }
            StudioIconButton("xmark", label: L10n.t("Cancel transfer of %@", transfer.name), size: .small) {
                confirmingCancel = true
            }
            .help(L10n.t("Cancel"))
        }
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
            return A11y.sentence(L10n.t("Paused"), A11y.percent(transfer.fraction),
                                 L10n.t("%1$@ of %2$@", A11y.bytes(transfer.bytes), A11y.bytes(transfer.total)))
        case .finished:
            return A11y.sentence(L10n.t("Finished"), transfer.total > 0 ? A11y.bytes(transfer.total) : nil)
        case .cancelled:
            return L10n.t("Cancelled")
        case .failed(let message):
            return L10n.t("Failed, %@", message)
        }
    }
}

/// A live conversion: what it makes and from what, its progress, and Cancel.
struct MenuBarMediaRow: View {
    let job: MediaJobCenter.Job
    let center: MediaJobCenter

    var body: some View {
        let info = MediaJobPresentation(job: job)
        WindowsCompactCard {
            StudioFileArtwork(kind: info.kind, size: .s, isFaded: info.isQuiet)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("%1$@ → %2$@", job.sourceName, job.kind.outputExtension.uppercased()))
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                StudioLinearProgress(fraction: job.fraction,
                                     tone: job.state == .cancelling ? .paused : .warn,
                                     height: StudioLinearProgress.thinHeight)
                    .padding(.vertical, Studio.Space.hair)
                Text(info.subtitle)
                    .studioFont(.caption)
                    .foregroundStyle(info.tone == .warn ? Studio.Palette.warn : Studio.Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(job.kind.activeTitle)
            .accessibilityValue(A11y.sentence(job.sourceName, info.spokenStatus))
            StudioIconButton("xmark", label: L10n.t("Cancel %@", L10n.midSentence(job.kind.activeTitle)),
                             size: .small) {
                center.cancel(job.id)
            }
            .disabled(job.state == .cancelling && !job.isStopStuck())
        }
    }
}

/// The auto quit/sleep/shutdown countdown, with the same Cancel and "do it now" as the window's card.
struct MenuBarCountdownSection: View {
    @ObservedObject var countdown: AutoShutdownCountdown

    var body: some View {
        if case .counting(let intent, let remaining) = countdown.phase {
            HStack(alignment: .top, spacing: Studio.Space.m) {
                StudioProgressArc(fraction: Double(remaining) / Double(AutoShutdownCountdown.defaultSeconds),
                                  tone: .warn, diameter: 40, lineWidth: 4,
                                  accessibilityLabel: L10n.t("Time left")) {
                    Text(verbatim: "\(remaining)")
                        .font(StudioFonts.font(.display, size: 12, weight: 700, tabularNumbers: true))
                        .foregroundStyle(Studio.Palette.ink)
                }
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    Text(AutoShutdownCountdown.title(for: intent))
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AutoShutdownCountdown.message(remaining: remaining))
                        .studioFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Studio.Palette.ink2)
                    HStack(spacing: Studio.Space.s) {
                        Button(L10n.t("Cancel"), role: .cancel) { countdown.cancel() }
                            .buttonStyle(.studio(.secondary, size: .small))
                            .keyboardShortcut(.defaultAction)
                        Button(AutoShutdownCountdown.actionTitle(for: intent),
                               systemImage: AutoShutdownCountdownCard.symbol(for: intent)) { countdown.performNow() }
                            .buttonStyle(.studio(.primary, size: .small))
                    }
                    .padding(.top, Studio.Space.hair)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Studio.Space.m)
            .background(Studio.Palette.warnSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.compactCard,
                                                                        style: .continuous))
            .accessibilityElement(children: .contain)
            .padding(.horizontal, Studio.Space.l)
            .padding(.bottom, Studio.Space.sm)
        }
    }
}
