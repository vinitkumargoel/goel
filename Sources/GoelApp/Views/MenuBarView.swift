import SwiftUI
import AppKit
import GoelCore

/// The main `WindowGroup`'s scene id. `openWindow` is the only way to build a window once the last
/// one is closed, and it can only address a group that declares an id.
enum MainWindowID {
    static let value = "main"
    static let history = "history"
    static let player = "player"
}

struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    /// Observed so the transfer rows redraw; read through `vm.sftpTransfers`.
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @Environment(\.openWindow) private var openWindow

    @State private var measuredListHeight: CGFloat = 0

    private var queue: MenuBarQueue { MenuBarQueue(tasks: vm.tasks) }

    /// `.failed` is terminal, so `MenuBarQueue` never lists one; this section is where they surface.
    private var attention: MenuBarAttention { MenuBarAttention(tasks: vm.tasks) }

    private var activeTransfers: [SFTPTransfer] {
        // Paused rows stay listed: the menu bar is where a resume is most reachable.
        vm.sftpTransfers.filter { $0.occupiesDestination }
    }

    private var justFinished: [DownloadTask] { MenuBarJustFinished(tasks: vm.tasks).shown }

    var body: some View {
        let attention = self.attention
        let justFinished = self.justFinished
        let queue = self.queue
        let listedTasks = queue.listed
        VStack(spacing: 0) {
            header(queued: queue.total, failures: attention.total)
            Divider()
            // The window's blocking card is invisible in menu-bar-only mode, yet the countdown still fires.
            MenuBarCountdownSection(countdown: vm.autoShutdownCountdown)
            if listedTasks.isEmpty && activeTransfers.isEmpty && vm.mediaLiveCount == 0
                && attention.shown.isEmpty && justFinished.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // Not a `LazyVStack`: asked for the zero height measured below it would build no rows and stay zero.
                    VStack(spacing: 0) {
                        if !attention.shown.isEmpty {
                            sectionLabel(L10n.t("Needs attention"))
                            ForEach(attention.shown) { task in
                                MenuBarFailedRow(task: task, vm: vm, onOpen: { open(task) })
                                Divider()
                            }
                            if !listedTasks.isEmpty { sectionLabel(L10n.t("In progress")) }
                        }
                        ForEach(listedTasks) { task in
                            MenuBarDownloadRow(task: task, vm: vm, onOpen: { open(task) })
                            Divider()
                        }
                        if queue.hiddenCount > 0 {
                            moreRow(queue)
                            Divider()
                        }
                        if !activeTransfers.isEmpty {
                            sectionLabel(L10n.t("SFTP Transfers"))
                            ForEach(activeTransfers) { t in
                                MenuBarSFTPTransferRow(
                                    transfer: t,
                                    vm: vm,
                                    onShowRemoteFolder: {
                                        vm.revealSFTPTransfer(t)
                                        activateMainWindow()
                                    })
                                Divider()
                            }
                        }
                        if vm.mediaLiveCount > 0 {
                            sectionLabel(L10n.t("Conversions"))
                            MenuBarMediaSection(center: vm.mediaJobs)
                        }
                        if !justFinished.isEmpty {
                            sectionLabel(L10n.t("Just finished"))
                            ForEach(justFinished) { task in
                                MenuBarFinishedRow(task: task, vm: vm, onOpen: { open(task) })
                                Divider()
                            }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: listHeight)
                .onPreferenceChange(ListHeightKey.self) { measuredListHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    /// A `.window` `MenuBarExtra` sizes to the content's *ideal* height, which a `ScrollView` has none of.
    private var listHeight: CGFloat {
        min(max(measuredListHeight, Self.minListHeight), Self.maxListHeight)
    }

    private static let minListHeight: CGFloat = 62
    private static let maxListHeight: CGFloat = 360

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .scaledFont(size: Theme.TextSize.micro, weight: .bold)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    /// Rows past the cap still count and still get a way in: the header used to report only the
    /// eight drawn, so twelve downloads read "Downloads · 8".
    private func moreRow(_ queue: MenuBarQueue) -> some View {
        Button {
            vm.showFilter(queue.hiddenFilter)
            activateMainWindow()
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t("%d more in Goel°", queue.hiddenCount))
                    .scaledFont(size: Theme.TextSize.meta, weight: .semibold)
                Image(systemName: "chevron.right").scaledFont(size: 9, weight: .bold)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(L10n.t("%d more downloads", queue.hiddenCount),
                    hint: L10n.t("Opens the main window with them listed."))
    }

    private func open(_ task: DownloadTask) {
        vm.reveal(task.id)
        activateMainWindow()
    }

    private func header(queued: Int, failures: Int) -> some View {
        let count = queued + activeTransfers.count + vm.mediaLiveCount
        return HStack(spacing: 12) {
            Text(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads · %d", count))
                .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                .accessibilityLabel(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads, %d in progress", count))
                .accessibilityAddTraits(.isHeader)
            if failures > 0 {
                Text("\(failures)")
                    .scaledFont(size: Theme.TextSize.caption, weight: .bold, monospacedDigit: true)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Theme.red, in: Capsule())
                    .foregroundStyle(Theme.onRed)
                    .help(L10n.t("%d failed", failures))
                    .accessibilityLabel(L10n.t("%d failed", failures))
            }
            Spacer(minLength: 0)
            speedStat(symbol: "arrow.down", value: telemetry.displayedCombinedSpeed.down, color: Theme.green)
            speedStat(symbol: "arrow.up", value: telemetry.displayedCombinedSpeed.up, color: Theme.teal)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func speedStat(symbol: String, value: Double, color: Color) -> some View {
        SpeedStat(symbol: symbol, speed: value, color: color, size: 12, minWidth: 66)
    }

    private var emptyState: some View {
        EmptyStateView(systemImage: "arrow.down.circle", title: L10n.t("No active downloads"),
                       subtitle: L10n.t("Add a URL or magnet link to get started."),
                       symbolSize: 26, symbolStyle: .tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            MenuBarSpeedControls(vm: vm)

            Button(action: addDownload) {
                HStack(spacing: 7) {
                    Image(systemName: "plus").scaledFont(size: Theme.TextSize.body, weight: .bold)
                    Text(L10n.t("Add download")).scaledFont(size: Theme.TextSize.title, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                .foregroundStyle(Theme.onAccent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(L10n.t("Add download"), hint: L10n.t("Opens the main window’s add sheet."))

            HStack(spacing: 0) {
                MenuBarPauseAllButton(state: vm.commandState, vm: vm)
                Spacer(minLength: 0)
                Button(action: openApp) {
                    HStack(spacing: 4) {
                        Text(L10n.t("Open Goel°")).scaledFont(size: Theme.TextSize.meta)
                        Image(systemName: "chevron.right").scaledFont(size: 9, weight: .bold)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton(L10n.t("Open Goel main window"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func addDownload() {
        activateMainWindow()
        vm.isAddSheetPresented = true
    }

    private func openApp() { activateMainWindow() }

    private func activateMainWindow() {
        MainWindowPresenter.register { openWindow(id: MainWindowID.value) }
        MainWindowPresenter.activate()
    }
}

/// The auto quit/sleep/shutdown countdown, with the same Cancel and "do it now" as the window's card.
private struct MenuBarCountdownSection: View {
    @ObservedObject var countdown: AutoShutdownCountdown

    var body: some View {
        if case .counting(let intent, let remaining) = countdown.phase {
            VStack(alignment: .leading, spacing: 6) {
                Text(AutoShutdownCountdown.title(for: intent))
                    .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AutoShutdownCountdown.message(remaining: remaining))
                    .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L10n.t("Cancel"), role: .cancel) { countdown.cancel() }
                        .keyboardShortcut(.defaultAction)
                    Button(AutoShutdownCountdown.actionTitle(for: intent)) { countdown.performNow() }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
            Divider()
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The toolbar's Pause All / Resume All, same state and wording. Observes ``CommandState`` itself:
/// a nested ObservableObject read through the view model never invalidates.
private struct MenuBarPauseAllButton: View {
    @ObservedObject var state: CommandState
    let vm: AppViewModel

    var body: some View {
        let snapshot = state.snapshot
        let pausing = snapshot.pauseAllPauses
        Button {
            if pausing { vm.pauseAll() } else { vm.resumeAll() }
        } label: {
            Label(pausing ? L10n.t("Pause All") : L10n.t("Resume All"),
                  systemImage: pausing ? "pause.fill" : "play.fill")
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.pauseAllEnabled)
        .a11yButton(pausing ? L10n.t("Pause all downloads") : L10n.t("Resume all downloads"))
    }
}

private struct MenuBarDownloadRow: View {
    @EnvironmentObject private var telemetry: TelemetryStore
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileTypeIcon(type: task.fileType, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.compactDisplayName)
                        .scaledFont(size: Theme.TextSize.body, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(task.name)
                    KindBadge(task: task)
                    Spacer(minLength: 0)
                }
                MiniProgressBar(task: task)
                HStack(spacing: 5) {
                    Text(task.statusDetailText)
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let speed = trailingSpeed {
                        Text(speed.text)
                            .scaledFont(size: Theme.TextSize.caption, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(speed.color)
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
            StateButton(task: task, vm: vm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var trailingSpeed: (text: String, color: Color)? {
        let speed = telemetry.displaySpeed(for: task)
        if speed.down > 0 { return (speed.down.speedString, Theme.green) }
        if speed.up > 0 { return (speed.up.speedString, Theme.teal) }
        return nil
    }
}

/// A failed download: the reason in red and a Retry, so the popover doesn't claim "No active
/// downloads" while one sits broken.
private struct MenuBarFailedRow: View {
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileTypeIcon(type: task.fileType, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.compactDisplayName)
                    .scaledFont(size: Theme.TextSize.body, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let error) = task.status {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(Theme.red)
                        .lineLimit(2)
                        .help(A11y.sentence(error.message, FailureAdvice.hint(for: error)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .a11yGroup(label: A11y.sentence(task.compactDisplayName, task.accessibilityStatusName))
            .accessibilityAction(named: L10n.t("Show in Goel°"), onOpen)
            Button(L10n.t("Retry")) { vm.retry(task.id) }
                .buttonStyle(TintedPillButtonStyle(tint: Theme.red))
                .a11yButton(L10n.t("Retry %@", task.name))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A download that finished in the last day: open it or show it in Finder from the menu bar.
private struct MenuBarFinishedRow: View {
    let task: DownloadTask
    let vm: AppViewModel
    let onOpen: () -> Void
    @State private var hovered = false

    private var fileURL: URL { URL(fileURLWithPath: task.savePath) }

    var body: some View {
        HStack(spacing: 10) {
            FileTypeIcon(type: task.fileType, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .scaledFont(size: Theme.TextSize.body, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.name)
                if let completedAt = task.completedAt {
                    // Rendered by SwiftUI so "2 min ago" keeps counting while the popover is open.
                    Text(completedAt, format: .relative(presentation: .named))
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .environment(\.locale, DisplayFormat.appLocale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: L10n.t("Show in Goel°"), onOpen)
            .accessibilityAction(named: L10n.t("Quick Look")) { QuickLookPresenter.shared.present(fileURL) }
            // Hover reveals Quick Look, so the resting row stays as quiet as before.
            if hovered {
                IconButton(symbol: "eye", help: L10n.t("Quick Look"), size: 11,
                           spokenLabel: L10n.t("Quick Look %@", task.name)) {
                    QuickLookPresenter.shared.present(fileURL)
                }
            }
            IconButton(symbol: "magnifyingglass", help: L10n.t("Show in Finder"), size: 11,
                       spokenLabel: L10n.t("Show %@ in Finder", task.name)) {
                vm.revealInFinder(task)
            }
            Button(L10n.t("Open")) { vm.openFile(task) }
                .buttonStyle(TintedPillButtonStyle(tint: Theme.green))
                .a11yButton(L10n.t("Open %@", task.name))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // Drag the finished file straight out of the popover into Finder, Mail, a chat…
        .onDrag { NSItemProvider(object: fileURL as NSURL) }
        .help(L10n.t("Drag the file out to use it anywhere"))
    }
}

/// The status bar's speed controls, for menu-bar-only use: the snail toggles the global limit
/// and the segments switch profile, through the same view-model actions.
private struct MenuBarSpeedControls: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        let settings = vm.settings
        let snailLocked = vm.managedPolicy.isLocked(.speedLimitEnabled)
        let profileLocked = vm.managedPolicy.isLocked(.selectedProfileName)
        HStack(spacing: 8) {
            Button(action: vm.toggleSnail) {
                HStack(spacing: 5) {
                    Snail()
                        .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 13)
                    Text(SpeedProfileText.pill(limitEnabled: settings.speedLimitEnabled,
                                               profile: settings.selectedProfile))
                        .scaledFont(size: Theme.TextSize.caption, weight: .medium, monospacedDigit: true)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(settings.speedLimitEnabled ? Theme.orange.opacity(0.18)
                                                                      : Color.primary.opacity(0.08)))
                .foregroundStyle(settings.speedLimitEnabled ? Theme.orange : Color.secondary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(snailLocked)
            .help(snailLocked ? AppViewModel.managedFootnote : L10n.t("Toggle global speed limit"))
            .a11yButton(L10n.t("Global speed limit"),
                        hint: snailLocked ? AppViewModel.managedFootnote
                                          : L10n.t("Activate to turn the speed limit on or off."))
            .accessibilityValue(settings.speedLimitEnabled
                                ? L10n.t("On, %@ profile", settings.selectedProfileName)
                                : L10n.t("Off, unlimited"))

            Spacer(minLength: 0)

            Picker(L10n.t("Queue profile"), selection: Binding(
                get: { vm.settings.selectedProfileName },
                set: { vm.setProfile($0) })) {
                ForEach(settings.profiles) { profile in
                    Text(profile.name)
                        .help(SpeedProfileText.queueSummary(profile, limitEnabled: settings.speedLimitEnabled))
                        .tag(profile.name)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(profileLocked)
            .help(SpeedProfileText.queueSummary(settings.selectedProfile, limitEnabled: settings.speedLimitEnabled))
            .accessibilityValue(SpeedProfileText.spokenQueueSummary(
                settings.selectedProfile, limitEnabled: settings.speedLimitEnabled))
        }
    }
}

/// What "In progress" lists: running rows first, then waiting ones, capped so the popover stays
/// short — but counted in full, so the header and the "N more" row tell the truth.
struct MenuBarQueue {
    static let maxListedRows = 8

    let listed: [DownloadTask]
    let total: Int
    /// Where "N more" lands: Active when every hidden row is running, else the whole list.
    let hiddenFilter: SidebarFilter

    var hiddenCount: Int { total - listed.count }

    init(tasks: [DownloadTask], limit: Int = Self.maxListedRows) {
        let active = tasks.filter { $0.status.isActive }
        let pending = tasks.filter { !$0.status.isActive && !$0.status.isTerminal }
        let all = active + pending
        listed = Array(all.prefix(max(0, limit)))
        total = all.count
        hiddenFilter = all.dropFirst(listed.count).allSatisfy { $0.status.isActive } ? .active : .all
    }
}

/// What "Just finished" lists: the newest few downloads completed in the last day whose file
/// is still there to open.
struct MenuBarJustFinished {
    static let limit = 3
    static let window: TimeInterval = 24 * 60 * 60

    let shown: [DownloadTask]

    init(tasks: [DownloadTask], now: Date = Date(), limit: Int = Self.limit) {
        let cutoff = now.addingTimeInterval(-Self.window)
        shown = Array(tasks
            .filter { task in
                guard task.status == .completed, !task.isFileMissing,
                      let done = task.completedAt else { return false }
                return done >= cutoff && done <= now.addingTimeInterval(60)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(max(0, limit)))
    }
}

/// Which failures the menu bar lists: the newest few, plus how many there are in all.
struct MenuBarAttention {
    static let limit = 3

    let shown: [DownloadTask]
    let total: Int

    /// One pass over the queue, keeping only the newest `limit` failures in a small sorted buffer:
    /// the menu redraws often and a full sort of every failure was wasted on three rows.
    init(tasks: [DownloadTask], limit: Int = Self.limit) {
        var count = 0
        var newest: [DownloadTask] = []
        newest.reserveCapacity(limit + 1)
        for task in tasks where task.status.isFailed {
            count += 1
            guard limit > 0 else { continue }
            if newest.count == limit, let last = newest.last, task.addedAt <= last.addedAt { continue }
            let slot = newest.firstIndex { task.addedAt > $0.addedAt } ?? newest.endIndex
            newest.insert(task, at: slot)
            if newest.count > limit { newest.removeLast() }
        }
        total = count
        shown = newest
    }
}

private struct MenuBarSFTPTransferRow: View {
    let transfer: SFTPTransfer
    let vm: AppViewModel
    let onShowRemoteFolder: () -> Void
    @State private var confirmingCancel = false

    var body: some View {
        SFTPTransferRow(
            transfer: transfer,
            density: .full,
            serverLabel: vm.server(transfer.connectionID)?.label ?? L10n.t("Server"),
            onCancel: { confirmingCancel = true },
            onRetry: { vm.retrySFTPTransfer(transfer.id) },
            onPause: { vm.pauseSFTPTransfer(transfer.id) },
            onResume: { vm.resumeSFTPTransfer(transfer.id) },
            onShowRemoteFolder: onShowRemoteFolder)
        .confirmationDialog(
            transfer.cancelQuestion,
            isPresented: $confirmingCancel, titleVisibility: .visible
        ) {
            Button(L10n.t("Stop Transfer"), role: .destructive) { vm.cancelSFTPTransfer(transfer.id) }
            Button(L10n.t("Keep Going"), role: .cancel) {}
        } message: {
            Text(L10n.t("“%@” will stop transferring and be removed from the list.", transfer.name))
        }
    }
}

/// Observes ``MediaJobCenter`` directly: a nested `ObservableObject` read via ``AppViewModel`` never invalidates.
private struct MenuBarMediaSection: View {

    @ObservedObject var center: MediaJobCenter

    var body: some View {
        ForEach(center.jobs.filter { $0.state.isLive }) { job in
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .scaledFont(size: Theme.TextSize.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                    .a11yDecorative()
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.kind.activeTitle)
                        .scaledFont(size: Theme.TextSize.body, weight: .medium)
                        .lineLimit(1)
                    Text(job.sourceName)
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let fraction = job.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                Button {
                    center.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: Theme.TextSize.body)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(job.state == .cancelling && !job.isStopStuck())
                .accessibilityLabel(L10n.t("Cancel %@", L10n.midSentence(job.kind.activeTitle)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
        }
    }
}

/// Drawn into a single template `NSImage` because the menu bar clips a two-line SwiftUI stack.
struct MenuBarSpeedLabel: View {
    @ObservedObject var telemetry: TelemetryStore

    var body: some View {
        // `.equatable()` gates the image-allocating redraw to real changes of the 2 Hz read-out.
        SpeedContent(sample: telemetry.displayedCombinedSpeed).equatable()
            // Always alive while the menu-bar item shows, so a banner click can build a window.
            .registersMainWindowOpener()
    }

    private struct SpeedContent: View, Equatable {
        let sample: SpeedSample

        var body: some View {
            if sample.down > 0 || sample.up > 0 {
                Image(nsImage: MenuBarSpeedLabel.speedImage(down: sample.down, up: sample.up))
                    .accessibilityLabel(
                        L10n.t("Goel downloads. Downloading at %1$@, uploading at %2$@.",
                               A11y.speed(sample.down), A11y.speed(sample.up)))
            } else {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel(L10n.t("Goel downloads. Idle."))
            }
        }

        static func == (a: SpeedContent, b: SpeedContent) -> Bool { a.sample == b.sample }
    }

    private static func compact(_ bytesPerSec: Double) -> String {
        bytesPerSec > 0 ? Int64(bytesPerSec).byteString + "/s" : "0"
    }

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private static let fixedWidth: CGFloat =
        ceil(("↓ 8888.88 MB/s" as NSString).size(withAttributes: [.font: labelFont]).width) + 2

    static func speedImage(down: Double, up: Double) -> NSImage {
        let downText = "↓ " + compact(down)
        let upText   = "↑ " + compact(up)
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]

        let lineH = ceil(("↑ 0" as NSString).size(withAttributes: attrs).height)
        let width = fixedWidth
        let height = max(NSStatusBar.system.thickness, lineH * 2)

        func drawRightAligned(_ text: String, atY y: CGFloat) {
            let w = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: NSPoint(x: width - w - 1, y: y), withAttributes: attrs)
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // NSImage origin is bottom-left, so the upload row draws lower and download a line-height above it.
        let bottomY = (height - lineH * 2) / 2
        drawRightAligned(upText,   atY: bottomY)
        drawRightAligned(downText, atY: bottomY + lineH)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
