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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if activeTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activeTasks) { task in
                            MenuBarDownloadRow(task: task, vm: vm)
                            Divider()
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(activeTasks.isEmpty ? "Downloads" : "Active · \(activeTasks.count)")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            speedStat(symbol: "arrow.down", value: vm.totalDownloadSpeed, color: Theme.green)
            speedStat(symbol: "arrow.up", value: vm.totalUploadSpeed, color: Theme.teal)
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

    /// Bring the app forward and surface its main window (the popover dismisses
    /// itself once focus leaves it). The status-bar popover is a panel that can't
    /// become main, so the first `canBecomeMain` window is the real app window.
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
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

/// The status-item label: two stacked lines — download speed on top (green),
/// upload speed on bottom (teal) — while anything is transferring; a single
/// glyph when idle. Observes the view model directly so it re-renders on each
/// progress tick.
///
/// The two lines are drawn into a single `NSImage` rather than a SwiftUI
/// `VStack`, because the macOS menu bar gives a `MenuBarExtra` label only one
/// line's worth of vertical space and clips a two-line stack to its top row. A
/// pre-rendered image of the full menu-bar thickness sidesteps that and always
/// shows both rows.
struct MenuBarSpeedLabel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        if vm.tasks.contains(where: { $0.status.isActive }) {
            Image(nsImage: Self.speedImage(down: vm.totalDownloadSpeed,
                                           up: vm.totalUploadSpeed))
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    /// Compact per-line speed for the cramped menu bar, e.g. "14.2 MB/s"
    /// (or "0" at rest).
    private static func compact(_ bytesPerSec: Double) -> String {
        bytesPerSec > 0 ? Int64(bytesPerSec).byteString + "/s" : "0"
    }

    /// Render "↓ <down>" over "↑ <up>" into one menu-bar-height image. Colored
    /// (not a template) so the green/teal tinting survives; system colors keep it
    /// legible in both the light and dark menu bar.
    static func speedImage(down: Double, up: Double) -> NSImage {
        let downText = "↓ " + compact(down)
        let upText   = "↑ " + compact(up)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let downAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemGreen]
        let upAttrs:   [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemTeal]

        let dSize = (downText as NSString).size(withAttributes: downAttrs)
        let uSize = (upText   as NSString).size(withAttributes: upAttrs)
        let lineH = ceil(max(dSize.height, uSize.height))
        let width = ceil(max(dSize.width, uSize.width)) + 2
        let height = max(NSStatusBar.system.thickness, lineH * 2)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // NSImage origin is bottom-left, so the upload row draws lower and the
        // download row a line-height above it; the pair is centred vertically.
        let bottomY = (height - lineH * 2) / 2
        (upText   as NSString).draw(at: NSPoint(x: 1, y: bottomY), withAttributes: upAttrs)
        (downText as NSString).draw(at: NSPoint(x: 1, y: bottomY + lineH), withAttributes: downAttrs)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
