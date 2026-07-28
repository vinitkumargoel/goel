import SwiftUI
import AppKit
import GoelCore

struct DownloadsEmptyState: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettingsWindow

    @State private var clipboardLink: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 38))
                    .foregroundStyle(.quaternary)
                    .a11yDecorative()
                Text(L10n.t("Nothing downloading yet"))
                    .scaledFont(size: 14)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(clipboardLink == nil
                     ? L10n.t("Add a link and it will show up here.")
                     : L10n.t("There's a link on your clipboard — start with that one."))
                    .scaledFont(size: 12)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 12) {
                EmptyStateAction(
                    symbol: "doc.on.clipboard",
                    title: L10n.t("Paste a link"),
                    detail: clipboardLink.map(Self.shorten) ?? L10n.t("URL, magnet, or .m3u8 stream"),
                    isPrimary: clipboardLink != nil,
                    action: pasteLink)

                EmptyStateAction(
                    symbol: "arrow.down.to.line",
                    title: L10n.t("Drop a file"),
                    detail: L10n.t("Drag a .torrent or a link onto this window"),
                    isPrimary: false,
                    a11yLabel: L10n.t("Show or hide the Drop Basket"),
                    a11yHint: L10n.t("Opens a small floating window that accepts dragged links and torrent files. Activating again closes it."),
                    action: { DropBasketController.shared.toggle() })

                EmptyStateAction(
                    symbol: "link.badge.plus",
                    title: L10n.t("Open Link Grabber"),
                    detail: L10n.t("List every file linked from a page"),
                    isPrimary: false,
                    action: { vm.isLinkGrabberPresented = true })
            }
            .frame(maxWidth: 560)

            hints

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear(perform: refreshClipboard)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
    }

    private var hints: some View {
        VStack(spacing: 5) {
            HStack(spacing: 14) {
                EmptyStateHint(symbol: "safari", text: L10n.t("Browser extension")) {
                    showSettings(.browser)
                }
                EmptyStateHint(symbol: "command", text: L10n.t("Press ⌘K for everything")) {
                    CommandPaletteBus.toggle()
                }
                EmptyStateHint(symbol: "display",
                               text: vm.settings.remoteAccessEnabled ? L10n.t("Remote portal") : L10n.t("Add from your phone")) {
                    showSettings(.remote)
                }
            }
        }
        .padding(.top, 2)
    }

    private func pasteLink() {
        vm.isAddSheetPresented = true
    }

    private func showSettings(_ pane: SettingsView.Pane) {
        SettingsRoute.shared.request(pane)
        openSettingsWindow()
    }

    private func refreshClipboard() {
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let clip, !clip.isEmpty, AppViewModel.parseSource(clip) != nil else {
            clipboardLink = nil
            return
        }
        clipboardLink = clip
    }

    private static func shorten(_ locator: String) -> String {
        guard locator.count > 44 else { return locator }
        return locator.prefix(24) + "…" + locator.suffix(16)
    }
}

private struct EmptyStateAction: View {
    let symbol: String
    let title: String
    let detail: String
    let isPrimary: Bool
    var a11yLabel: String? = nil
    var a11yHint: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(isPrimary ? Theme.accent : .secondary)
                    .frame(height: 22)
                Text(title)
                    .scaledFont(size: 12.5, weight: .semibold)
                Text(detail)
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .padding(.horizontal, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isPrimary ? Theme.accent.opacity(0.55) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .a11yGroup(label: a11yLabel ?? title, hint: a11yHint ?? detail)
        .accessibilityAddTraits(.isButton)
    }

    private var fill: Color {
        if isPrimary { return Theme.accent.opacity(hovering ? 0.14 : 0.08) }
        return Color.primary.opacity(hovering ? 0.08 : 0.035)
    }
}

private struct EmptyStateHint: View {
    let symbol: String
    let text: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(text).scaledFont(size: 11)
            }
            .foregroundStyle(hovering ? Theme.accent : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .a11yGroup(label: text.replacingOccurrences(of: "⌘K", with: L10n.t("Command K")))
        .accessibilityAddTraits(.isButton)
    }
}
