import SwiftUI
import AppKit
import GoelCore

/// The menu bar popover: what needs you first, then progress, SFTP transfers, conversions and
/// what just finished, with the speed limit and queue profile on top and Add / Open / Pause All
/// below.
struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        MenuBarPopover(center: vm.mediaJobs, commands: vm.commandState)
    }
}

/// The popover's content. Observes ``MediaJobCenter`` and ``CommandState`` itself: a nested
/// `ObservableObject` read through the view model never invalidates.
struct MenuBarPopover: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    /// Observed so the transfer rows redraw; read through `vm.sftpTransfers`.
    @EnvironmentObject private var sftpStore: SFTPTransferStore
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var center: MediaJobCenter
    @ObservedObject var commands: CommandState
    /// Snapshot seams: sample transfers and jobs in place of the live stores.
    var transfersOverride: [SFTPTransfer]?
    var jobsOverride: [MediaJobCenter.Job]?
    var countdownOverride: AutoShutdownCountdown?

    @State private var measuredListHeight: CGFloat = 0

    static let width: CGFloat = 400
    private static let minListHeight: CGFloat = 62
    private static let maxListHeight: CGFloat = 480

    private var activeTransfers: [SFTPTransfer] {
        // Paused rows stay listed: the menu bar is where a resume is most reachable.
        (transfersOverride ?? vm.sftpTransfers).filter { $0.occupiesDestination }
    }

    private var liveJobs: [MediaJobCenter.Job] {
        (jobsOverride ?? center.jobs).filter { $0.state.isLive }
    }

    var body: some View {
        // `.failed` is terminal, so `MenuBarQueue` never lists one; Needs attention is where they surface.
        let attention = MenuBarAttention(tasks: vm.tasks)
        let justFinished = MenuBarJustFinished(tasks: vm.tasks).shown
        let queue = MenuBarQueue(tasks: vm.tasks)
        let transfers = activeTransfers
        let jobs = liveJobs
        let isEmpty = queue.listed.isEmpty && transfers.isEmpty && jobs.isEmpty
            && attention.shown.isEmpty && justFinished.isEmpty
        VStack(spacing: 0) {
            header(count: queue.total + transfers.count + jobs.count, failures: attention.total)
            // The window's blocking card is invisible in menu-bar-only mode, yet the countdown still fires.
            MenuBarCountdownSection(countdown: countdownOverride ?? vm.autoShutdownCountdown)
            if isEmpty {
                emptyState
            } else {
                ScrollView {
                    // Not a `LazyVStack`: asked for the zero height measured below it would build no rows and stay zero.
                    sections(attention: attention, queue: queue, transfers: transfers, jobs: jobs,
                             justFinished: justFinished)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: MenuBarListHeightKey.self, value: geo.size.height)
                        })
                }
                .frame(height: listHeight)
                .onPreferenceChange(MenuBarListHeightKey.self) { measuredListHeight = $0 }
            }
            footer
        }
        .frame(width: Self.width)
        .background(Studio.Palette.sheet)
    }

    /// A `.window` `MenuBarExtra` sizes to the content's *ideal* height, which a `ScrollView` has none of.
    private var listHeight: CGFloat {
        min(max(measuredListHeight, Self.minListHeight), Self.maxListHeight)
    }

    // MARK: Header

    private func header(count: Int, failures: Int) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            HStack(alignment: .center, spacing: Studio.Space.s) {
                Text(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads · %d", count))
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .accessibilityLabel(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads, %d in progress", count))
                    .accessibilityAddTraits(.isHeader)
                if failures > 0 {
                    StudioPill(L10n.t("%d failed", failures), tone: .bad)
                        .help(L10n.t("%d failed", failures))
                        .accessibilityLabel(L10n.t("%d failed", failures))
                }
                Spacer(minLength: Studio.Space.s)
                speeds
            }
            MenuBarSpeedControls(vm: vm)
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.top, Studio.Space.l)
        .padding(.bottom, Studio.Space.m)
    }

    private var speeds: some View {
        let speed = telemetry.displayedCombinedSpeed
        return VStack(alignment: .trailing, spacing: 1) {
            Text(verbatim: "↓ " + speed.down.speedString)
                .foregroundStyle(speed.down > 0 ? Studio.Palette.accent : Studio.Palette.ink3)
            Text(verbatim: "↑ " + speed.up.speedString)
                .foregroundStyle(speed.up > 0 ? Studio.Palette.upload : Studio.Palette.ink3)
        }
        .studioFont(.mono)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Speed"))
        .accessibilityValue(L10n.t("Downloading at %1$@, uploading at %2$@",
                                   A11y.speed(speed.down), A11y.speed(speed.up)))
    }

    // MARK: Sections

    private func sections(attention: MenuBarAttention, queue: MenuBarQueue, transfers: [SFTPTransfer],
                          jobs: [MediaJobCenter.Job], justFinished: [DownloadTask]) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            if !attention.shown.isEmpty {
                sectionLabel(L10n.t("Needs attention"), tint: Studio.Palette.bad)
                ForEach(attention.shown) { task in
                    MenuBarFailedRow(task: task, vm: vm, onOpen: { open(task) })
                }
            }
            if !queue.listed.isEmpty {
                sectionLabel(L10n.t("In progress"))
                ForEach(queue.listed) { task in
                    MenuBarDownloadRow(task: task, vm: vm, onOpen: { open(task) })
                }
                if queue.hiddenCount > 0 { moreRow(queue) }
            }
            if !transfers.isEmpty {
                sectionLabel(L10n.t("SFTP Transfers"))
                ForEach(transfers) { transfer in
                    MenuBarSFTPTransferRow(
                        transfer: transfer,
                        serverLabel: vm.server(transfer.connectionID)?.label ?? L10n.t("Server"),
                        vm: vm,
                        onShowRemoteFolder: {
                            vm.revealSFTPTransfer(transfer)
                            activateMainWindow()
                        })
                }
            }
            if !jobs.isEmpty {
                sectionLabel(L10n.t("Conversions"))
                ForEach(jobs) { job in
                    MenuBarMediaRow(job: job, center: center)
                }
            }
            if !justFinished.isEmpty {
                sectionLabel(L10n.t("Just finished"))
                ForEach(justFinished) { task in
                    MenuBarFinishedRow(task: task, vm: vm, onOpen: { open(task) })
                }
            }
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.top, Studio.Space.xxs)
        .padding(.bottom, Studio.Space.ml)
    }

    private func sectionLabel(_ text: String, tint: Color = Studio.Palette.ink3) -> some View {
        WindowsEyebrow(text, tint: tint)
            .padding(.top, Studio.Space.xxs)
            .padding(.leading, Studio.Space.xxs)
    }

    /// Rows past the cap still count and still get a way in: the header used to report only the
    /// eight drawn, so twelve downloads read "Downloads · 8".
    private func moreRow(_ queue: MenuBarQueue) -> some View {
        Button {
            vm.showFilter(queue.hiddenFilter)
            activateMainWindow()
        } label: {
            HStack(spacing: Studio.Space.xxs) {
                Text(L10n.t("%d more in Goel°", queue.hiddenCount))
                Image(systemName: "chevron.right").font(StudioFonts.font(.ui, size: 9, weight: 700))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.studio(.ghost, size: .small, fullWidth: true))
        .a11yButton(L10n.t("%d more downloads", queue.hiddenCount),
                    hint: L10n.t("Opens the main window with them listed."))
    }

    private var emptyState: some View {
        VStack(spacing: Studio.Space.sm) {
            Image(systemName: "arrow.down")
                .font(StudioFonts.font(.ui, size: 20, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 48, height: 48)
                .background(Studio.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.compactCard, style: .continuous))
                .accessibilityHidden(true)
            Text(L10n.t("No active downloads"))
                .studioFont(.title3)
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("Add a URL or magnet link to get started."))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Studio.Space.xxl)
        .padding(.horizontal, Studio.Space.l)
    }

    // MARK: Footer

    private var footer: some View {
        let snapshot = commands.snapshot
        let pausing = snapshot.pauseAllPauses
        return HStack(spacing: Studio.Space.s) {
            Button(L10n.t("Add download"), systemImage: "plus", action: addDownload)
                .buttonStyle(.studio(.primary, size: .small))
                .a11yButton(L10n.t("Add download"), hint: L10n.t("Opens the main window’s add sheet."))
            Button(L10n.t("Open Goel°"), action: activateMainWindow)
                .buttonStyle(.studio(.secondary, size: .small))
                .a11yButton(L10n.t("Open Goel main window"))
            Spacer(minLength: Studio.Space.s)
            Button(pausing ? L10n.t("Pause All") : L10n.t("Resume All"),
                   systemImage: pausing ? "pause.fill" : "play.fill") {
                if pausing { vm.pauseAll() } else { vm.resumeAll() }
            }
            .buttonStyle(.studio(.ghost, size: .small))
            .disabled(!snapshot.pauseAllEnabled)
            .a11yButton(pausing ? L10n.t("Pause all downloads") : L10n.t("Resume all downloads"))
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.vertical, Studio.Space.m)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
    }

    // MARK: Actions

    private func open(_ task: DownloadTask) {
        vm.reveal(task.id)
        activateMainWindow()
    }

    private func addDownload() {
        activateMainWindow()
        vm.isAddSheetPresented = true
    }

    private func activateMainWindow() {
        MainWindowPresenter.register { openWindow(id: MainWindowID.value) }
        MainWindowPresenter.activate()
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
        HStack(spacing: Studio.Space.s) {
            Button(action: vm.toggleSnail) {
                Label(SpeedProfileText.pill(limitEnabled: settings.speedLimitEnabled,
                                            profile: settings.selectedProfile),
                      systemImage: "tortoise")
                    .monospacedDigit()
            }
            .buttonStyle(StudioPillButtonStyle(isOn: settings.speedLimitEnabled, size: .small))
            .disabled(snailLocked)
            .help(snailLocked ? AppViewModel.managedFootnote : L10n.t("Toggle global speed limit"))
            .a11yButton(L10n.t("Global speed limit"),
                        hint: snailLocked ? AppViewModel.managedFootnote
                                          : L10n.t("Activate to turn the speed limit on or off."))
            .accessibilityValue(settings.speedLimitEnabled
                                ? L10n.t("On, %@ profile", settings.selectedProfileName)
                                : L10n.t("Off, unlimited"))

            StudioSegmentedControl(
                selection: Binding(get: { vm.settings.selectedProfileName }, set: { vm.setProfile($0) }),
                segments: settings.profiles.map { profile in
                    StudioSegment(profile.name, title: profile.name,
                                  help: SpeedProfileText.queueSummary(
                                      profile, limitEnabled: settings.speedLimitEnabled))
                },
                size: .small, fullWidth: true,
                accessibilityLabel: L10n.t("Queue profile"))
                .disabled(profileLocked)
                .help(SpeedProfileText.queueSummary(settings.selectedProfile, limitEnabled: settings.speedLimitEnabled))
                .accessibilityValue(SpeedProfileText.spokenQueueSummary(
                    settings.selectedProfile, limitEnabled: settings.speedLimitEnabled))
        }
    }
}

private struct MenuBarListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
