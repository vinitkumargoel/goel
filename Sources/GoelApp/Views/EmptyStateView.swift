import SwiftUI
import AppKit
import GoelCore

// ============================================================================
// The genuinely-empty download list.
//
// This is a different situation from "your filter matched nothing", which
// ``DownloadListView`` already handles with the shared ``EmptyStateView`` chrome
// in `SharedViews.swift`. That case wants a quiet dead end. *This* case is the
// first thing a new user sees, and a symbol plus the words "no downloads" tells
// them something they can already see.
//
// So it offers the three ways in instead — paste, drop, grab — as real controls
// that do the thing, not as instructions to go and find a menu. The quieter row
// underneath names the surfaces that are otherwise invisible from here.
//
// The type is `DownloadsEmptyState`, not `EmptyStateView`: that name is already
// taken by the shared symbol-and-caption block, and the two are used side by
// side within the same file.
// ============================================================================

/// The affordance-first placeholder shown when the queue is completely empty.
struct DownloadsEmptyState: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettingsWindow

    /// A link sitting on the pasteboard right now, if it is something we could
    /// actually download. Re-read on appear and whenever the app is reactivated,
    /// because the interesting case is "user copied a link, switched back".
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

    /// Open the add sheet. The sheet already auto-pastes a downloadable link
    /// from the clipboard, so this is the same gesture whether or not one is
    /// there — no second, subtly-different paste path to keep in sync.
    private func pasteLink() {
        vm.isAddSheetPresented = true
    }

    /// Open the Settings window already on the relevant pane. The pane travels
    /// through ``SettingsRoute``; opening the window is a separate call because
    /// `openSettings` only exists inside a view's environment.
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
        // This is the first screen a new user meets, and each card is a symbol
        // over two lines of text — three elements for one button. One element,
        // with the detail line as its hint since it explains rather than names.
        .a11yGroup(label: title, hint: detail)
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
