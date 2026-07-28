import SwiftUI
import AppKit
import GoelCore

/// The menu-bar dropdown: live ↓/↑ totals, active downloads as rich rows, and a footer to add,
/// pause/start everything, or open the main window. A `.window`-style `MenuBarExtra`.
struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Measured height of the row list, used to size the scroll view (see
    /// ``listHeight`` for why this is needed).
    @State private var measuredListHeight: CGFloat = 0

    /// Everything currently transferring — downloading, verifying, resolving
    /// metadata, or seeding (the same predicate the sidebar's "Active" uses).
    private var activeTasks: [DownloadTask] {
        vm.tasks.filter { $0.status.isActive }
    }

    /// The rows the popover lists: every unfinished download, transferring first then queued — so it
    /// stays useful when the concurrency cap leaves most waiting. Capped to keep the popover compact.
    private var listedTasks: [DownloadTask] {
        let active = vm.tasks.filter { $0.status.isActive }
        let pending = vm.tasks.filter { !$0.status.isActive && !$0.status.isTerminal }
        return Array((active + pending).prefix(Self.maxListedRows))
    }

    /// Upper bound on popover rows (the main window shows the rest).
    private static let maxListedRows = 8

    /// In-flight SFTP uploads/downloads (browser transfer center), listed below
    /// the download queue so a background upload is visible from the menu bar.
    private var activeTransfers: [SFTPTransfer] {
        vm.sftpTransfers.filter { $0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if listedTasks.isEmpty && activeTransfers.isEmpty && vm.mediaLiveCount == 0 {
                emptyState
            } else {
                ScrollView {
                    // A plain `VStack`, not a `LazyVStack`: the height below is derived from this stack's own
                    // measurement, and a lazy stack asked for zero height would build no rows and report zero back.
                    VStack(spacing: 0) {
                        ForEach(listedTasks) { task in
                            MenuBarDownloadRow(task: task, vm: vm)
                            Divider()
                        }
                        if !activeTransfers.isEmpty {
                            sectionLabel("SFTP Transfers")
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
                        // Conversions keep the app alive after its last window closes, so they must be reachable from
                        // the menu bar — otherwise Goel° sits in the Dock doing invisible, uncancellable work.
                        if vm.mediaLiveCount > 0 {
                            sectionLabel("Conversions")
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

    /// Height to give the row list. A `.window` `MenuBarExtra` sizes to the content's *ideal* height,
    /// and a `ScrollView` has none — so the measured content height (clamped) is fed back.
    private var listHeight: CGFloat {
        min(max(measuredListHeight, Self.minListHeight), Self.maxListHeight)
    }

    /// Enough to show one row before the first measurement lands.
    private static let minListHeight: CGFloat = 62
    /// Past this the list scrolls; the full queue lives in the main window.
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

    // MARK: Header

    private var header: some View {
        // Count what the popover actually lists (unfinished downloads + live SFTP transfers), so the
        // header number matches the rows below rather than only the transferring subset.
        let count = listedTasks.count + activeTransfers.count + vm.mediaLiveCount
        return HStack(spacing: 12) {
            Text(count == 0 ? "Downloads" : "Downloads · \(count)")
                .scaledFont(size: 13, weight: .semibold)
                // "Downloads · 4" reads as "Downloads middle dot four".
                .accessibilityLabel(count == 0 ? "Downloads" : "Downloads, \(count) in progress")
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

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(systemImage: "arrow.down.circle", title: "No active downloads",
                       subtitle: "Add a URL or magnet link to get started.",
                       symbolSize: 26, symbolStyle: .tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 9) {
            Button(action: addDownload) {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text("Add download").scaledFont(size: 13, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton("Add download", hint: "Opens the main window's add sheet.")

            HStack(spacing: 0) {
                Button(action: pauseOrResumeAll) {
                    Label(activeTasks.isEmpty ? "Start all" : "Pause all",
                          systemImage: activeTasks.isEmpty ? "play.fill" : "pause.fill")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton(activeTasks.isEmpty ? "Start all downloads" : "Pause all downloads")
                Spacer(minLength: 0)
                Button(action: openApp) {
                    HStack(spacing: 4) {
                        Text("Open Goel°").scaledFont(size: 11.5)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // "Goel°" ends in a degree sign, which VoiceOver reads as
                // "degrees"; and the chevron is a separate unnamed element.
                .a11yButton("Open Goel main window")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Actions

    private func addDownload() {
        activateMainWindow()
        vm.isAddSheetPresented = true
    }

    private func openApp() { activateMainWindow() }

    private func pauseOrResumeAll() {
        if activeTasks.isEmpty { vm.resumeAll() } else { vm.pauseAll() }
    }

    /// Bring the app forward and surface its main downloads window. The `Settings` scene's window is
    /// also `canBecomeMain`, so it must be excluded explicitly or it may get raised instead.
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI hosts the `Settings` scene under this well-known identifier.
        let settingsID = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        let window = NSApp.windows.first { $0.canBecomeMain && $0.identifier != settingsID }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Carries the measured height of the popover's row stack up to ``MenuBarView``,
/// which needs a concrete height for the scroll view around it.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One rich row in the menu-bar popover, mirroring the main list row but tuned for the narrow
/// width. Holds `vm` as a plain reference so it rebuilds only when its own `task` changes.
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
            // Same treatment as the main list row: everything collapses to one spoken item, the state button
            // stays reachable, and the label carries identity only so the row doesn't re-speak every second.
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

    /// The dominant per-row rate: download speed while fetching, upload while seeding, nothing when
    /// idle. Reads the sampled display speed so the row updates on the main list's calm cadence.
    private var trailingSpeed: (text: String, color: Color)? {
        let speed = vm.displaySpeed(for: task)
        if speed.down > 0 { return (speed.down.speedString, Theme.green) }
        if speed.up > 0 { return (speed.up.speedString, Theme.teal) }
        return nil
    }
}

/// Menu-bar SFTP row: shared ``SFTPTransferRow`` plus a native confirm dialog
/// (app overlay only lives on the main window, not this scene).
private struct MenuBarSFTPTransferRow: View {
    let transfer: SFTPTransfer
    let vm: AppViewModel
    let onShowRemoteFolder: () -> Void
    @State private var confirmingCancel = false

    var body: some View {
        SFTPTransferRow(
            transfer: transfer,
            density: .full,
            serverLabel: vm.server(transfer.connectionID)?.label ?? "Server",
            onCancel: { confirmingCancel = true },
            onRetry: { vm.retrySFTPTransfer(transfer.id) },
            onShowRemoteFolder: onShowRemoteFolder)
        .confirmationDialog(
            "Cancel this \(transfer.cancelNoun)?",
            isPresented: $confirmingCancel, titleVisibility: .visible
        ) {
            Button("Stop Transfer", role: .destructive) { vm.cancelSFTPTransfer(transfer.id) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("“\(transfer.name)” will stop transferring and be removed from the list.")
        }
    }
}

/// Live conversions in the menu-bar popover. Its own view observing ``MediaJobCenter`` directly,
/// because a nested `ObservableObject` read through ``AppViewModel`` never invalidates the parent.
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
                .accessibilityLabel("Cancel \(job.kind.activeTitle)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
        }
    }
}

/// The status-item label: stacked ↓/↑ speeds while transferring, one glyph when idle. Drawn into a
/// single template `NSImage` because the menu bar clips a two-line SwiftUI stack; fixed width.
struct MenuBarSpeedLabel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        // The view model publishes at ~10 Hz but the label depends only on `displayedCombinedSpeed`.
        // Gate the image-allocating redraw on an Equatable subview so it rebuilds only when that changes.
        SpeedContent(sample: vm.displayedCombinedSpeed).equatable()
    }

    /// The actual label content, keyed purely on the sampled speed.
    private struct SpeedContent: View, Equatable {
        let sample: AppViewModel.SpeedSample

        var body: some View {
            if sample.down > 0 || sample.up > 0 {
                // The two speed lines are drawn into a bitmap, which is completely opaque to VoiceOver — it is
                // pixels, not text. Restate both rates as the image's label.
                Image(nsImage: MenuBarSpeedLabel.speedImage(down: sample.down, up: sample.up))
                    .accessibilityLabel(
                        "Goel downloads. Downloading at \(A11y.speed(sample.down)), "
                        + "uploading at \(A11y.speed(sample.up)).")
            } else {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel("Goel downloads. Idle.")
            }
        }

        static func == (a: SpeedContent, b: SpeedContent) -> Bool { a.sample == b.sample }
    }

    /// Compact per-line speed for the cramped menu bar, e.g. "14.2 MB/s"
    /// (or "0" at rest).
    private static func compact(_ bytesPerSec: Double) -> String {
        bytesPerSec > 0 ? Int64(bytesPerSec).byteString + "/s" : "0"
    }

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    /// A constant width sized to a worst-case rate, so the item is rock-steady
    /// regardless of the current speed (right-aligned within this box).
    private static let fixedWidth: CGFloat =
        ceil(("↓ 8888.88 MB/s" as NSString).size(withAttributes: [.font: labelFont]).width) + 2

    /// Render "↓ <down>" over "↑ <up>", right-aligned within ``fixedWidth``, into
    /// one menu-bar-height template image.
    static func speedImage(down: Double, up: Double) -> NSImage {
        let downText = "↓ " + compact(down)
        let upText   = "↑ " + compact(up)
        // Template images ignore colour and are masked by alpha, so labelColor is
        // just a legible opaque fill; AppKit picks the real menu-bar tint.
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
        // NSImage origin is bottom-left, so the upload row draws lower and the
        // download row a line-height above it; the pair is centred vertically.
        let bottomY = (height - lineH * 2) / 2
        drawRightAligned(upText,   atY: bottomY)
        drawRightAligned(downText, atY: bottomY + lineH)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
