import SwiftUI
import AppKit
import GoelCore

/// The first run: a welcome mat, not a blank table. The omnibox sits in the middle (it replaces
/// the header's while the queue is empty), and six cards show every other way in. A link already
/// on the clipboard is offered straight away.
struct DownloadsEmptyState: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.openSettings) private var openSettingsWindow
    @Environment(\.mainWindowPreview) private var preview

    @Binding var omniboxText: String
    var omniboxFocus: FocusState<Bool>.Binding

    @State private var clipboardLink: String?

    private static let columns = Array(repeating: GridItem(.flexible(minimum: 150, maximum: 250),
                                                           spacing: Studio.Space.ml),
                                       count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: Studio.Space.xl) {
                VStack(spacing: Studio.Space.s) {
                    Text(L10n.t("Nothing downloading yet"))
                        .studioFont(.title1.size(36))
                        .foregroundStyle(Studio.Palette.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(clipboardLink == nil
                         ? L10n.t("Add a link and it will show up here.")
                         : L10n.t("There’s a link on your clipboard — start with that one."))
                        .studioFont(.body.size(15))
                        .foregroundStyle(Studio.Palette.ink2)
                        .multilineTextAlignment(.center)
                }
                MainOmnibox(text: $omniboxText, isFocused: omniboxFocus) {
                    if let clipboardLink, vm.clipboardSuggestion == nil, omniboxText.isEmpty {
                        StudioOmniboxSuggestion { clipboardRow(clipboardLink) }
                    }
                }
                .frame(maxWidth: 700)
                ways
                    .frame(maxWidth: 780)
                    .padding(.top, Studio.Space.s)
            }
            .padding(.horizontal, Studio.Space.xxl)
            .padding(.top, 52)
            .padding(.bottom, Studio.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .onAppear(perform: refreshClipboard)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
    }

    private func clipboardRow(_ link: String) -> some View {
        Group {
            Image(systemName: "link")
                .font(StudioFonts.font(.ui, size: 15, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 32, height: 32)
                .background(Studio.Palette.accentSoft,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Link on your clipboard"))
                    .studioFont(.eyebrow)
                    .foregroundStyle(Studio.Palette.accent)
                // The row is wide: let middle truncation fit the link instead of a fixed cut.
                Text(link)
                    .studioFont(.monoBody)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.t("Add"), systemImage: "arrow.right") {
                vm.addSheetPrefill = link
                vm.isAddSheetPresented = true
            }
            .buttonStyle(.studio(.primary, size: .small))
            .accessibilityLabel(L10n.t("Add copied link to downloads"))
        }
    }

    private var ways: some View {
        LazyVGrid(columns: Self.columns, spacing: Studio.Space.ml) {
            EmptyStateWay(
                symbol: "link",
                title: L10n.t("Paste a link"),
                detail: clipboardLink.map(Self.shorten) ?? L10n.t("URL, magnet, or .m3u8 stream"),
                isPrimary: clipboardLink != nil,
                action: { vm.isAddSheetPresented = true })
            EmptyStateWay(
                symbol: "basket",
                title: L10n.t("Drop Basket"),
                detail: L10n.t("A floating target for dragged links and .torrent files"),
                keys: "⇧⌘B",
                a11yLabel: L10n.t("Show or hide the Drop Basket"),
                a11yHint: L10n.t("Opens a small floating window that accepts dragged links and torrent files. "
                                 + "Activating again closes it."),
                action: { DropBasketController.shared.toggle() })
            EmptyStateWay(
                symbol: "link.badge.plus",
                title: L10n.t("Open Link Grabber"),
                detail: L10n.t("List every file linked from a page"),
                keys: "⇧⌘L",
                action: { vm.isLinkGrabberPresented = true })
            EmptyStateWay(
                symbol: "safari",
                title: L10n.t("Browser extension"),
                detail: L10n.t("Send downloads from Safari, Chrome or Firefox"),
                action: { showSettings(.browser) })
            EmptyStateWay(
                symbol: "command",
                title: L10n.t("Press ⌘K for everything"),
                detail: L10n.t("Every action and setting, by name"),
                a11yLabel: L10n.t("Press Command K for everything"),
                action: { CommandPaletteBus.toggle() })
            EmptyStateWay(
                symbol: "iphone",
                title: vm.settings.remoteAccessEnabled ? L10n.t("Remote portal") : L10n.t("Add from your phone"),
                detail: vm.settings.remoteAccessEnabled
                    ? L10n.t("Add from your phone") : L10n.t("Turn on Web Access in Settings"),
                action: { showSettings(.remote) })
        }
    }

    private func showSettings(_ pane: SettingsView.Pane) {
        SettingsRoute.shared.request(pane)
        openSettingsWindow()
    }

    private func refreshClipboard() {
        if let preview {
            clipboardLink = preview.clipboardLink
            return
        }
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

/// One way in (`.way`): an accent tile, a display title and a line of detail.
private struct EmptyStateWay: View {
    let symbol: String
    let title: String
    let detail: String
    var keys: String?
    var isPrimary = false
    var a11yLabel: String?
    var a11yHint: String?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.boardCard, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                Image(systemName: symbol)
                    .font(StudioFonts.font(.ui, size: 17, weight: 650))
                    .foregroundStyle(isPrimary ? Studio.Palette.onAccent : Studio.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(isPrimary ? Studio.Palette.accent : Studio.Palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
                Text(title)
                    .studioFont(.lane)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
                    Text(detail)
                        .studioFont(.callout.weight(400))
                        .foregroundStyle(Studio.Palette.ink2)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    if let keys { StudioKeyCaps(keys) }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(shape.fill(Studio.Palette.card).studioElevation(hovering ? .floating : .card))
            .overlay(shape.strokeBorder(isPrimary || hovering ? Studio.Palette.accentLine : Studio.Palette.cardEdge,
                                        lineWidth: isPrimary ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .studioFocusRing(isFocused, shape: shape)
        .onHover { hovering = $0 }
        .animation(Studio.Motion.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel ?? title)
        .accessibilityHint(a11yHint ?? detail)
        .accessibilityAddTraits(.isButton)
    }
}
