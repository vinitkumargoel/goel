import SwiftUI
import AppKit
import GoelCore

// The genuinely-empty download list — distinct from "your filter matched nothing". This is a new
// user's first screen, so it offers the three ways in (paste, drop, grab) as real controls.

/// The affordance-first placeholder shown when the queue is completely empty.
struct DownloadsEmptyState: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettingsWindow

    /// A link on the pasteboard right now, if it is something we could download. Re-read on appear
    /// and on reactivation, because the interesting case is "user copied a link, switched back".
    @State private var clipboardLink: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 38))
                    .foregroundStyle(.quaternary)
                    .a11yDecorative()
                Text("Nothing downloading yet")
                    .scaledFont(size: 14)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(clipboardLink == nil
                     ? "Add a link and it will show up here."
                     : "There's a link on your clipboard — start with that one.")
                    .scaledFont(size: 12)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 12) {
                EmptyStateAction(
                    symbol: "doc.on.clipboard",
                    title: "Paste a link",
                    detail: clipboardLink.map(Self.shorten) ?? "URL, magnet, or .m3u8 stream",
                    isPrimary: clipboardLink != nil,
                    action: pasteLink)

                EmptyStateAction(
                    symbol: "arrow.down.to.line",
                    title: "Drop a file",
                    detail: "Drag a .torrent or a link onto this window",
                    isPrimary: false,
                    // The visible copy teaches the pointer gesture, but the click toggles the Drop Basket. Spoken as
                    // written it would be an instruction a non-pointer user cannot follow, so name the real effect.
                    a11yLabel: "Show or hide the Drop Basket",
                    a11yHint: "Opens a small floating window that accepts dragged links and torrent files. Activating again closes it.",
                    action: { DropBasketController.shared.toggle() })

                EmptyStateAction(
                    symbol: "link.badge.plus",
                    title: "Open Link Grabber",
                    detail: "List every file linked from a page",
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
        // A link copied in the browser is only interesting once the user comes
        // back to this window, which is exactly when this fires.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
    }

    /// The quieter second tier: surfaces that exist but that nothing on this
    /// screen would otherwise reveal.
    private var hints: some View {
        VStack(spacing: 5) {
            HStack(spacing: 14) {
                EmptyStateHint(symbol: "safari", text: "Browser extension") {
                    showSettings(.browser)
                }
                EmptyStateHint(symbol: "command", text: "Press ⌘K for everything") {
                    CommandPaletteBus.toggle()
                }
                EmptyStateHint(symbol: "display",
                               text: vm.settings.remoteAccessEnabled ? "Remote portal" : "Add from your phone") {
                    showSettings(.remote)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: Actions

    /// Open the add sheet, which already auto-pastes a downloadable link — so this is the same
    /// gesture either way, with no second, subtly-different paste path to keep in sync.
    private func pasteLink() {
        vm.isAddSheetPresented = true
    }

    /// Open the Settings window already on the relevant pane. The pane travels through
    /// ``SettingsRoute``; opening the window is separate because `openSettings` only exists in a view.
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

    /// Middle-truncate a locator so a long URL still shows both its host and
    /// its file name in a narrow card.
    private static func shorten(_ locator: String) -> String {
        guard locator.count > 44 else { return locator }
        return locator.prefix(24) + "…" + locator.suffix(16)
    }
}

// MARK: - Pieces

/// One of the three big affordances: a bordered, hoverable card that performs
/// its action on click.
private struct EmptyStateAction: View {
    let symbol: String
    let title: String
    let detail: String
    /// Tints the card when it is the obvious next move (a link is on the
    /// clipboard). Purely visual — every card stays equally clickable.
    let isPrimary: Bool
    /// Spoken label and hint, for when the visible copy describes a gesture rather than what clicking
    /// does. Default to `title`/`detail`, which is correct whenever the two agree.
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
        // This is a new user's first screen, and each card is a symbol over two lines — three elements
        // for one button. One element, with the detail line as its hint since it explains rather than names.
        .a11yGroup(label: a11yLabel ?? title, hint: a11yHint ?? detail)
        .accessibilityAddTraits(.isButton)
    }

    private var fill: Color {
        if isPrimary { return Theme.accent.opacity(hovering ? 0.14 : 0.08) }
        return Color.primary.opacity(hovering ? 0.08 : 0.035)
    }
}

/// A small text-and-symbol link in the second tier.
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
        // "Press ⌘K for everything" contains a glyph the ear can't parse; these
        // are links, and nothing but hover colour marks them as clickable.
        .a11yGroup(label: text.replacingOccurrences(of: "⌘K", with: "Command K"))
        .accessibilityAddTraits(.isButton)
    }
}
