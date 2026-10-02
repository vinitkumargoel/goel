import SwiftUI
import AppKit
import GoelCore

/// The feeds column: every feed with its unread count; right-click to edit its rule.
struct RSSFeedColumn: View {
    let data: RSSReaderData
    let selected: RSSFeed.ID?
    let actions: RSSReaderActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                WindowsEyebrow(L10n.t("Feeds"))
                    .padding(.horizontal, Studio.Space.sm)
                    .padding(.top, Studio.Space.xs)
                    .padding(.bottom, Studio.Space.xxs)
                ForEach(data.feeds) { feed in
                    RSSFeedRow(feed: feed, unread: data.unreadCount(feed.id), isSelected: feed.id == selected) {
                        actions.selectFeed(feed.id)
                    }
                    .contextMenu {
                        Button(L10n.t("Edit Rule…")) { actions.editRule(feed) }
                        Button(L10n.t("Mark All as Read")) { actions.markAllRead(feed.id) }
                    }
                }
                if data.feeds.isEmpty {
                    VStack(alignment: .leading, spacing: Studio.Space.s) {
                        Text(L10n.t("No feeds yet")).studioFont(.small).foregroundStyle(Studio.Palette.ink2)
                        Button(L10n.t("Add Feed"), systemImage: "plus", action: actions.addFeed)
                            .buttonStyle(.studio(.soft, size: .small))
                    }
                    .padding(.horizontal, Studio.Space.sm)
                    .padding(.top, Studio.Space.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, Studio.Space.ml)
        }
        .background(Studio.Palette.canvas)
    }
}

private struct RSSFeedRow: View {
    let feed: RSSFeed
    let unread: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                WindowsGlyphTile(symbol: feed.enabled ? "dot.radiowaves.up.forward" : "pause",
                                 tone: feed.enabled ? .accent : .neutral, side: 24)
                Text(feed.displayName)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(isSelected ? Studio.Palette.ink : Studio.Palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: Studio.Space.xxs)
                if unread > 0 {
                    Text(verbatim: "\(unread)")
                        .studioFont(.monoSmall)
                        .foregroundStyle(isSelected ? Studio.Palette.accent : Studio.Palette.ink3)
                }
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(minHeight: 34)
            .background {
                let shape = RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous)
                if isSelected {
                    shape.fill(Studio.Palette.card).studioElevation(.card)
                } else if hovered {
                    shape.fill(Studio.Palette.segment)
                }
            }
            .studioButtonFocusRing(shape: RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.studioPlain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feed.displayName)
        .accessibilityValue(A11y.sentence(L10n.t("%d unread", unread), feed.enabled ? nil : L10n.t("Paused")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The articles column: unread dot, title, date, and a Matches pill for what the rule takes.
struct RSSArticleColumn: View {
    let data: RSSReaderData
    let feed: RSSFeed?
    let actions: RSSReaderActions

    var body: some View {
        let items = data.items(feed)
        VStack(spacing: 0) {
            if let feed, let error = data.errors[feed.id] {
                StudioNote(tone: .bad, symbol: "exclamationmark.triangle", message: error)
                    .padding([.horizontal, .top], Studio.Space.sm)
            }
            ScrollView {
                LazyVStack(spacing: Studio.Space.xs) {
                    ForEach(items, id: \.key) { item in
                        // A button, so Tab and Space reach an article as well as a click does.
                        Button { actions.selectArticle(item.key) } label: {
                            RSSArticleRow(item: item,
                                          matches: feed.map {
                                              RSSRuleMatcher.matches(title: item.title, feed: $0)
                                          } ?? false,
                                          unread: !data.readKeys.contains(item.key),
                                          isSelected: data.selectedArticle == item.key,
                                          ruleName: feed?.displayName)
                                .studioButtonFocusRing(shape: RoundedRectangle(cornerRadius: Studio.Radius.compactCard,
                                                                               style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.studioPlain)
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(Studio.Space.sm)
            }
            .overlay { placeholder(isEmpty: items.isEmpty) }
        }
        .frame(maxHeight: .infinity)
        .background(Studio.Palette.well)
    }

    @ViewBuilder
    private func placeholder(isEmpty: Bool) -> some View {
        if let feed, data.loading.contains(feed.id), isEmpty {
            ProgressView().controlSize(.small).accessibilityLabel(L10n.t("Loading…"))
        } else if feed == nil {
            emptyText(L10n.t("Add a feed to see its articles"))
        } else if isEmpty, data.errors[feed?.id ?? UUID()] == nil {
            emptyText(L10n.t("No articles in this feed yet"))
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .studioFont(.small)
            .foregroundStyle(Studio.Palette.ink3)
            .multilineTextAlignment(.center)
            .padding(Studio.Space.xl)
    }
}

/// One article as a compact card.
struct RSSArticleRow: View {
    let item: RSSItem
    let matches: Bool
    let unread: Bool
    var isSelected = false
    var ruleName: String?

    var body: some View {
        WindowsCompactCard(isSelected: isSelected) {
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                Circle()
                    .fill(unread ? Studio.Palette.accent : .clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .studioFont(unread ? .bodyStrong : .body)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = item.published {
                        Text(unread ? date : L10n.t("%@ · read", date))
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .lineLimit(1)
                    }
                    if matches {
                        StudioPill(ruleName.map { L10n.t("Matches · %@", $0) } ?? L10n.t("Matches"),
                                   tone: .accent, showsDot: false)
                            .padding(.top, Studio.Space.hair)
                            .help(L10n.t("This feed’s rule would download it"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(unread || isSelected ? 1 : 0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(A11y.sentence(unread ? L10n.t("Unread") : nil, matches ? L10n.t("Matches the rule") : nil,
                                          item.published))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The preview: the article, what it links to, and Download / Open Link.
struct RSSPreviewPane: View {
    let data: RSSReaderData
    let feed: RSSFeed?
    let actions: RSSReaderActions

    var body: some View {
        if let item = data.article(in: feed) {
            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.m) {
                    WindowsEyebrow([feed?.displayName, item.published].compactMap { $0 }.joined(separator: " · "))
                    Text(item.title)
                        .studioFont(.title2)
                        .foregroundStyle(Studio.Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    let summary = RSSText.plain(item.summary)
                    if !summary.isEmpty {
                        Text(summary)
                            .studioFont(.body)
                            .lineSpacing(4)
                            .foregroundStyle(Studio.Palette.ink2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let locator = item.locator { enclosure(locator) }
                    buttons(item)
                }
                .padding(Studio.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { actions.markRead(item) }
            .onChange(of: item.key) { actions.markRead(item) }
        } else {
            StudioEmptyState(symbol: "dot.radiowaves.up.forward", title: L10n.t("Select an article"),
                             message: feed == nil ? nil : L10n.t("Its text and the file it links to show here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func enclosure(_ locator: String) -> some View {
        let name = URL(string: locator)?.lastPathComponent.removingPercentEncoding ?? locator
        let isMagnet = locator.lowercased().hasPrefix("magnet:")
        let type = isMagnet ? FileType.magnet : FileType.classify(fileName: name, isTorrent: name.hasSuffix(".torrent"))
        return WindowsCompactCard {
            StudioFileArtwork(kind: StudioArtKind(type), size: .s)
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Text(isMagnet ? L10n.t("Magnet link") : name)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(URL(string: locator)?.host ?? locator)
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ item: RSSItem) -> some View {
        HStack(spacing: Studio.Space.s) {
            if item.locator != nil {
                Button(L10n.t("Download"), systemImage: "arrow.down.circle") { actions.download(item, feed) }
                    .buttonStyle(.studio(.primary, size: .small))
            }
            if let url = RSSText.browserURL(item.link) {
                Button(L10n.t("Open Link"), systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.studio(.secondary, size: .small))
            }
        }
    }
}
