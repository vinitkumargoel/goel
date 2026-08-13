import SwiftUI
import AppKit
import GoelCore

/// The main `WindowGroup`'s scene id. `openWindow` is the only way to build a window once the last
/// one is closed, and it can only address a group that declares an id.
enum MainWindowID {
    static let value = "main"
}

struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var measuredListHeight: CGFloat = 0

    private var activeTasks: [DownloadTask] {
        vm.tasks.filter { $0.status.isActive }
    }

    private var listedTasks: [DownloadTask] {
        let active = vm.tasks.filter { $0.status.isActive }
        let pending = vm.tasks.filter { !$0.status.isActive && !$0.status.isTerminal }
        return Array((active + pending).prefix(Self.maxListedRows))
    }

    private static let maxListedRows = 8

    private var activeTransfers: [SFTPTransfer] {
        // Paused rows stay listed: the menu bar is where a resume is most reachable.
        vm.sftpTransfers.filter { $0.occupiesDestination }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if listedTasks.isEmpty && activeTransfers.isEmpty && vm.mediaLiveCount == 0 {
                emptyState
            } else {
                ScrollView {
                    // Not a `LazyVStack`: asked for the zero height measured below it would build no rows and stay zero.
                    VStack(spacing: 0) {
                        ForEach(listedTasks) { task in
                            MenuBarDownloadRow(task: task, vm: vm)
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
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    private var header: some View {
        let count = listedTasks.count + activeTransfers.count + vm.mediaLiveCount
        return HStack(spacing: 12) {
            Text(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads") + " · \(count)")
                .scaledFont(size: 13, weight: .semibold)
                .accessibilityLabel(count == 0 ? L10n.t("Downloads") : L10n.t("Downloads, %d in progress", count))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            speedStat(symbol: "arrow.down", value: vm.displayedCombinedSpeed.down, color: Theme.green)
            speedStat(symbol: "arrow.up", value: vm.displayedCombinedSpeed.up, color: Theme.teal)
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
            Button(action: addDownload) {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text(L10n.t("Add download")).scaledFont(size: 13, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(L10n.t("Add download"), hint: L10n.t("Opens the main window's add sheet."))

            HStack(spacing: 0) {
                Button(action: pauseOrResumeAll) {
                    Label(activeTasks.isEmpty ? L10n.t("Start all") : L10n.t("Pause all"),
                          systemImage: activeTasks.isEmpty ? "play.fill" : "pause.fill")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton(activeTasks.isEmpty ? L10n.t("Start all downloads") : L10n.t("Pause all downloads"))
                Spacer(minLength: 0)
                Button(action: openApp) {
                    HStack(spacing: 4) {
                        Text(L10n.t("Open Goel°")).scaledFont(size: 11.5)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
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

    private func pauseOrResumeAll() {
        if activeTasks.isEmpty { vm.resumeAll() } else { vm.pauseAll() }
    }

    /// The `Settings` window is also `canBecomeMain`, so it must be excluded or it gets raised instead.
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let settingsID = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier != settingsID }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The app keeps running in the menu bar after the last window closes, so there is
            // often nothing to raise — only SwiftUI can build a replacement.
            openWindow(id: MainWindowID.value)
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarDownloadRow: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            FileTypeIcon(type: task.fileType, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    KindBadge(task: task)
                    Spacer(minLength: 0)
                }
                MiniProgressBar(task: task)
                HStack(spacing: 5) {
                    Text(task.statusDetailText)
                        .scaledFont(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let speed = trailingSpeed {
                        Text(speed.text)
                            .scaledFont(size: 10.5, weight: .semibold, monospacedDigit: true)
                            .foregroundStyle(speed.color)
                    }
                }
            }
            .a11yGroup(label: A11y.sentence(task.name,
                                            task.accessibilityKindName,
                                            task.accessibilityStatusName),
                       value: task.accessibilityProgressValue)
            .accessibilityAddTraits(.updatesFrequently)
            StateButton(task: task, vm: vm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var trailingSpeed: (text: String, color: Color)? {
        let speed = vm.displaySpeed(for: task)
        if speed.down > 0 { return (speed.down.speedString, Theme.green) }
        if speed.up > 0 { return (speed.up.speedString, Theme.teal) }
        return nil
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
            L10n.t("Cancel this %@?", L10n.t(transfer.cancelNoun)),
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
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                    .a11yDecorative()
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.kind.activeTitle)
                        .scaledFont(size: 12, weight: .medium)
                        .lineLimit(1)
                    Text(job.sourceName)
                        .scaledFont(size: 10.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let fraction = job.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                Button {
                    center.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
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
    @ObservedObject var vm: AppViewModel

    var body: some View {
        // `.equatable()` gates the image-allocating redraw; the view model itself publishes at ~10 Hz.
        SpeedContent(sample: vm.displayedCombinedSpeed).equatable()
    }

    private struct SpeedContent: View, Equatable {
        let sample: AppViewModel.SpeedSample

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
