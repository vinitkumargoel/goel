import SwiftUI
import GoelCore

/// The RSS sidebar destination: feeds | articles | preview. Articles the feed's rule would
/// download are marked, so a rule can be checked against what the feed actually publishes.
struct RSSReaderView: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var model = RSSReaderModel.shared
    @State private var editing: RSSRuleRequest?

    private var feeds: [RSSFeed] { vm.settings.rssFeeds }
    private var feed: RSSFeed? { feeds.first { $0.id == model.selectedFeed } ?? feeds.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                RSSFeedColumn(feeds: feeds, selected: feed?.id, onEdit: { editing = RSSRuleRequest(feed: $0) })
                    .frame(width: 210)
                Divider()
                RSSArticleColumn(feed: feed)
                    .frame(minWidth: 240, maxWidth: .infinity)
                Divider()
                RSSPreviewPane(feed: feed)
                    .frame(width: 300)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $editing) { request in
            RSSRuleSheet(original: request.feed).environmentObject(vm)
        }
        .onChange(of: vm.filter) { model.close() }
        .onChange(of: vm.selectedServer) { _, server in if server != nil { model.close() } }
        .task(id: feed?.id) { await refreshSelected() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.close() } label: { Label(L10n.t("Downloads"), systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .help(L10n.t("Back to downloads"))
            Divider().frame(height: 18)
            Text(L10n.t("RSS")).scaledFont(size: Theme.TextSize.body, weight: .semibold)
            Spacer()
            Button { Task { await refreshSelected() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(feed == nil)
                .a11yButton(L10n.t("Refresh feed"))
            Button { editing = RSSRuleRequest(feed: nil) } label: { Label(L10n.t("Add Feed"), systemImage: "plus") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    private func refreshSelected() async {
        guard let feed else { return }
        model.selectedFeed = feed.id
        await model.refresh(feed, using: vm.manager)
    }
}

struct RSSRuleRequest: Identifiable {
    let id = UUID()
    /// nil adds a new feed.
    let feed: RSSFeed?
}

private struct RSSFeedColumn: View {
    let feeds: [RSSFeed]
    let selected: RSSFeed.ID?
    let onEdit: (RSSFeed) -> Void
    @ObservedObject private var model = RSSReaderModel.shared

    var body: some View {
        List(selection: Binding(get: { selected }, set: { model.selectedFeed = $0; model.selectedArticle = nil })) {
            ForEach(feeds) { feed in
                row(feed)
                    .tag(feed.id)
                    .contextMenu {
                        Button(L10n.t("Edit Rule…")) { onEdit(feed) }
                        Button(L10n.t("Mark All as Read")) { model.markAllRead(feed.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if feeds.isEmpty {
                Text(L10n.t("No feeds yet")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ feed: RSSFeed) -> some View {
        let unread = model.unreadCount(feed.id)
        return HStack {
            Image(systemName: feed.enabled ? "dot.radiowaves.up.forward" : "pause.circle")
                .foregroundStyle(feed.enabled ? Theme.orange : .secondary)
                .a11yDecorative()
            Text(feed.displayName).lineLimit(1)
            Spacer()
            if unread > 0 {
                Text(verbatim: "\(unread)").scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(L10n.t("%d unread", unread))
    }
}

private struct RSSArticleColumn: View {
    let feed: RSSFeed?
    @ObservedObject private var model = RSSReaderModel.shared

    private var items: [RSSItem] { feed.flatMap { model.articles[$0.id] } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if let feed, let error = model.errors[feed.id] {
                Text(error).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.red)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            List(selection: Binding(get: { model.selectedArticle }, set: { model.selectedArticle = $0 })) {
                ForEach(items, id: \.key) { item in
                    RSSArticleRow(item: item, matches: feed.map { RSSRuleMatcher.matches(title: item.title, feed: $0) } ?? false,
                                  unread: !model.readKeys.contains(item.key))
                        .tag(item.key)
                }
            }
            .listStyle(.inset)
            .overlay { overlay }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let feed, model.loading.contains(feed.id), items.isEmpty {
            ProgressView().controlSize(.small)
        } else if feed == nil {
            Text(L10n.t("Add a feed to see its articles")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
        }
    }
}

struct RSSArticleRow: View {
    let item: RSSItem
    let matches: Bool
    let unread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(unread ? Theme.accent : Color.clear).frame(width: 7, height: 7).padding(.top, 5)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .scaledFont(size: Theme.TextSize.body, weight: unread ? .semibold : .regular)
                    .lineLimit(2)
                if let date = item.published {
                    Text(date).scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if matches {
                Text(L10n.t("Matches"))
                    .scaledFont(size: Theme.TextSize.micro, weight: .semibold)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.green.opacity(0.18)))
                    .foregroundStyle(Theme.green)
                    .help(L10n.t("This feed’s rule would download it"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(A11y.sentence(unread ? L10n.t("Unread") : nil, matches ? L10n.t("Matches the rule") : nil))
    }
}

private struct RSSPreviewPane: View {
    let feed: RSSFeed?
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var model = RSSReaderModel.shared

    private var item: RSSItem? {
        guard let feed, let key = model.selectedArticle else { return nil }
        return model.articles[feed.id]?.first { $0.key == key }
    }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
                        .textSelection(.enabled)
                    actions(item)
                    Text(RSSText.plain(item.summary))
                        .scaledFont(size: Theme.TextSize.body)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear { model.markRead(item) }
                .onChange(of: item.key) { model.markRead(item) }
            } else {
                Text(L10n.t("Select an article"))
                    .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
                    .padding(20)
            }
        }
    }

    private func actions(_ item: RSSItem) -> some View {
        HStack {
            if let locator = item.locator {
                Button(L10n.t("Download")) {
                    let folder = feed?.saveDirectory.isEmpty == false ? feed?.saveDirectory : nil
                    vm.add(rawLines: locator, saveDirectory: folder, priority: .normal)
                }
                .buttonStyle(.borderedProminent)
            }
            if let url = RSSText.browserURL(item.link) {
                Button(L10n.t("Open Link")) { NSWorkspace.shared.open(url) }
            }
        }
    }
}
