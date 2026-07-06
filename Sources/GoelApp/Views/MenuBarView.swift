import SwiftUI
import AppKit
import GoelCore

/// The menu-bar (status item) dropdown — the "Rich list · inline controls"
/// concept. A compact popover with live ↓/↑ totals in the header, the active
/// downloads as rich rows (type icon, progress, status, per-row speed, and a
/// shared inline pause/resume button), and a footer to add a download, pause /
/// start everything, or jump to the main window.
///
/// Rendered as a `.window`-style `MenuBarExtra` so it can host this custom
/// SwiftUI UI rather than a plain `NSMenu`. It reuses the same row building
/// blocks as the main list (``FileTypeIcon`` / ``KindBadge`` / ``MiniProgressBar``
/// / ``StateButton``) so the look stays identical to the window.
struct MenuBarView: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Everything currently transferring — downloading, verifying, resolving
    /// metadata, or seeding (the same predicate the sidebar's "Active" uses).
    private var activeTasks: [DownloadTask] {
        vm.tasks.filter { $0.status.isActive }
    }

    /// In-flight SFTP uploads/downloads (browser transfer center), listed below
    /// the download queue so a background upload is visible from the menu bar.
    private var activeTransfers: [SFTPTransfer] {
        vm.sftpTransfers.filter { $0.isActive }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if activeTasks.isEmpty && activeTransfers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activeTasks) { task in
                            MenuBarDownloadRow(task: task, vm: vm)
                            Divider()
                        }
                        if !activeTransfers.isEmpty {
                            sectionLabel("SFTP Transfers")
                            ForEach(activeTransfers) { t in
                                MenuBarTransferRow(transfer: t, vm: vm)
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Header

    private var header: some View {
        let activeCount = activeTasks.count + activeTransfers.count
        return HStack(spacing: 12) {
            Text(activeCount == 0 ? "Downloads" : "Active · \(activeCount)")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            speedStat(symbol: "arrow.down", value: vm.combinedDownloadSpeed, color: Theme.green)
            speedStat(symbol: "arrow.up", value: vm.combinedUploadSpeed, color: Theme.teal)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func speedStat(symbol: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(value > 0 ? value.speedString : "—")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 66, alignment: .trailing)
        }
        .foregroundStyle(value > 0 ? color : Color.secondary)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No active downloads")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Add a URL or magnet link to get started.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 9) {
            Button(action: addDownload) {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text("Add download").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                Button(action: pauseOrResumeAll) {
                    Label(activeTasks.isEmpty ? "Start all" : "Pause all",
                          systemImage: activeTasks.isEmpty ? "play.fill" : "pause.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(action: openApp) {
                    HStack(spacing: 4) {
                        Text("Open Goel°").font(.system(size: 11.5))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    /// Bring the app forward and surface its main downloads window (the popover
    /// dismisses itself once focus leaves it). The status-bar popover is a panel
    /// that can't become main, but the SwiftUI `Settings` scene's window is also
    /// `canBecomeMain`, so it must be excluded explicitly — otherwise whichever
    /// main-capable window happens to be frontmost (possibly Settings) gets
    /// raised instead of the downloads window.
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI hosts the `Settings` scene under this well-known identifier.
        let settingsID = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        let window = NSApp.windows.first { $0.canBecomeMain && $0.identifier != settingsID }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One rich row in the menu-bar popover: type icon, name + kind badge, a thin
/// progress bar, a status/speed sub-line, and the shared inline state button.
/// Mirrors the main list row but tuned for the narrow popover width. Holds `vm`
/// as a plain reference (not `@EnvironmentObject`) so a row rebuilds only when
/// its own `task` changes, not on every other task's progress tick.
private struct MenuBarDownloadRow: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            FileTypeIcon(type: task.fileType, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    KindBadge(task: task)
                    Spacer(minLength: 0)
                }
                MiniProgressBar(task: task)
                HStack(spacing: 5) {
                    Text(task.statusDetailText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let speed = trailingSpeed {
                        Text(speed.text)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(speed.color)
                            .monospacedDigit()
                    }
                }
            }
            StateButton(task: task, vm: vm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    /// The dominant per-row rate: download speed while fetching, upload speed
    /// while seeding, nothing when idle.
    private var trailingSpeed: (text: String, color: Color)? {
        if task.downloadSpeed > 0 { return (task.downloadSpeed.speedString, Theme.green) }
        if task.uploadSpeed > 0 { return (task.uploadSpeed.speedString, Theme.teal) }
        return nil
    }
}

/// One in-flight SFTP transfer in the menu-bar popover: direction icon, name +
/// server, a thin progress bar, live speed (teal up / green down), and a cancel
/// button. Mirrors ``MenuBarDownloadRow`` but for the SFTP transfer center.
private struct MenuBarTransferRow: View {
    let transfer: SFTPTransfer
    let vm: AppViewModel

    // The app's custom confirm overlay only renders on the main window, not in
    // this separate menu-bar scene — so this surface asks with a native dialog.
    @State private var confirmingCancel = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.iconName(filledWhenFinished: false))
                .font(.system(size: 20))
                .foregroundStyle(transfer.direction == .upload ? Theme.teal : Theme.green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transfer.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(transfer.progressLabel)
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.fraction)
                HStack(spacing: 5) {
                    Text(vm.server(transfer.connectionID)?.label ?? "Server")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !transfer.speedLabel.isEmpty {
                        Text(transfer.speedLabel)
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(transfer.direction == .upload ? Theme.teal : Theme.green)
                    }
                }
            }
            Button { confirmingCancel = true } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .confirmationDialog(
            "Cancel this \(transfer.direction == .upload ? "upload" : "download")?",
            isPresented: $confirmingCancel, titleVisibility: .visible
        ) {
            Button("Stop Transfer", role: .destructive) { vm.cancelSFTPTransfer(transfer.id) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("“\(transfer.name)” will stop transferring and be removed from the list.")
        }
    }
}

/// The status-item label: two stacked lines — download speed on top, upload
/// speed on bottom — while anything is transferring; a single glyph when idle.
///
/// Reads ``AppViewModel/menuBarSpeed`` (sampled at 1 Hz) rather than the live
/// 10 Hz totals, so the label refreshes once a second and never flickers.
///
/// The two lines are drawn into a single `NSImage` rather than a SwiftUI
/// `VStack`, because the macOS menu bar gives a `MenuBarExtra` label only one
/// line's worth of vertical space and clips a two-line stack to its top row. A
/// pre-rendered image of the full menu-bar thickness sidesteps that and always
/// shows both rows.
///
/// The image is a **template** (`isTemplate = true`): macOS tints it to match
/// the menu bar — dark on a light bar, light on a dark bar — the way every other
/// menu-bar item behaves. (It used explicit green/teal, which disappeared
/// against a green wallpaper / tinted menu bar.) The image also keeps a **fixed
/// width** so the item never shifts as the numbers grow and shrink.
struct MenuBarSpeedLabel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        // The view model publishes at ~10 Hz, but the label's content depends only
        // on the 1 Hz `menuBarSpeed`. Gate the (image-allocating) redraw on an
        // Equatable subview so it rebuilds at most once per second.
        SpeedContent(sample: vm.menuBarSpeed).equatable()
    }

    /// The actual label content, keyed purely on the sampled speed.
    private struct SpeedContent: View, Equatable {
        let sample: AppViewModel.SpeedSample

        var body: some View {
            if sample.down > 0 || sample.up > 0 {
                Image(nsImage: MenuBarSpeedLabel.speedImage(down: sample.down, up: sample.up))
            } else {
                Image(systemName: "arrow.down.circle")
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
