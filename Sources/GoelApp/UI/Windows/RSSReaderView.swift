import SwiftUI
import GoelCore

/// The RSS destination: feeds | articles | preview. Articles the feed's rule would download carry
/// a Matches pill, so a rule can be checked against what the feed actually publishes.
struct RSSReaderView: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var model = RSSReaderModel.shared
    @State private var editing: RSSRuleRequest?

    /// Previews and snapshots pass fixed data; the app reads the shared reader model.
    private let preview: RSSReaderData?

    init(preview: RSSReaderData? = nil) {
        self.preview = preview
    }

    private var data: RSSReaderData {
        preview ?? RSSReaderData(feeds: vm.settings.rssFeeds, articles: model.articles, readKeys: model.readKeys,
                                 errors: model.errors, loading: model.loading,
                                 selectedFeed: model.selectedFeed, selectedArticle: model.selectedArticle)
    }

    var body: some View {
        let data = self.data
        let feed = data.feed
        VStack(spacing: 0) {
            toolbar(feed: feed)
            HStack(spacing: 0) {
                RSSFeedColumn(data: data, selected: feed?.id, actions: actions)
                    .frame(width: 210)
                Rectangle().fill(Studio.Palette.hairline).frame(width: 1)
                RSSArticleColumn(data: data, feed: feed, actions: actions)
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 320)
                Rectangle().fill(Studio.Palette.hairline).frame(width: 1)
                RSSPreviewPane(data: data, feed: feed, actions: actions)
                    .frame(minWidth: 280, maxWidth: .infinity)
            }
        }
        .background(Studio.Palette.canvas)
        .sheet(item: $editing) { request in
            RSSRuleSheet(original: request.feed).environmentObject(vm)
        }
        .onChange(of: model.wantsAddFeed, initial: true) { _, wanted in
            guard wanted else { return }
            model.wantsAddFeed = false
            editing = RSSRuleRequest(feed: nil)
        }
        .onChange(of: vm.filter) { if preview == nil { model.close() } }
        .onChange(of: vm.selectedServer) { _, server in if server != nil, preview == nil { model.close() } }
        .task(id: feed?.id) { await refreshSelected() }
    }

    private func toolbar(feed: RSSFeed?) -> some View {
        HStack(spacing: Studio.Space.s) {
            Button(L10n.t("Downloads"), systemImage: "chevron.left") { model.close() }
                .buttonStyle(.studio(.ghost, size: .small))
                .help(L10n.t("Back to downloads"))
            Rectangle().fill(Studio.Palette.hairlineStrong).frame(width: 1, height: 18)
            Text(L10n.t("Feeds"))
                .studioFont(.bodyStrong.size(13.5))
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Studio.Space.s)
            StudioIconButton("arrow.clockwise", label: L10n.t("Refresh feed"), size: .small) {
                Task { await refreshSelected() }
            }
            .disabled(feed == nil)
            Button(L10n.t("Add Feed"), systemImage: "plus") { editing = RSSRuleRequest(feed: nil) }
                .buttonStyle(.studio(.secondary, size: .small))
            Button(L10n.t("Edit Rule…")) { if let feed { editing = RSSRuleRequest(feed: feed) } }
                .buttonStyle(.studio(.secondary, size: .small))
                .disabled(feed == nil)
            Button(L10n.t("Mark All as Read")) { if let feed { actions.markAllRead(feed.id) } }
                .buttonStyle(.studio(.ghost, size: .small))
                .disabled(feed == nil || data.unreadCount(feed?.id) == 0)
        }
        .windowsToolbarChrome()
    }

    private var actions: RSSReaderActions {
        let isPreview = preview != nil
        return RSSReaderActions(
            selectFeed: { id in
                guard !isPreview else { return }
                model.selectedFeed = id
                model.selectedArticle = nil
            },
            selectArticle: { key in if !isPreview { model.selectedArticle = key } },
            markRead: { item in if !isPreview { model.markRead(item) } },
            markAllRead: { id in if !isPreview { model.markAllRead(id) } },
            editRule: { feed in editing = RSSRuleRequest(feed: feed) },
            addFeed: { editing = RSSRuleRequest(feed: nil) },
            download: { item, feed in
                guard let locator = item.locator else { return }
                let folder = feed?.saveDirectory.isEmpty == false ? feed?.saveDirectory : nil
                vm.add(rawLines: locator, saveDirectory: folder, priority: .normal)
            })
    }

    private func refreshSelected() async {
        guard preview == nil, let feed = data.feed else { return }
        model.selectedFeed = feed.id
        await model.refresh(feed, using: vm.manager)
    }
}

/// What the reader shows: the feeds, their fetched articles, and what is read and selected.
struct RSSReaderData {
    var feeds: [RSSFeed]
    var articles: [RSSFeed.ID: [RSSItem]] = [:]
    var readKeys: Set<String> = []
    var errors: [RSSFeed.ID: String] = [:]
    var loading: Set<RSSFeed.ID> = []
    var selectedFeed: RSSFeed.ID?
    var selectedArticle: String?

    /// The selected feed, or the first one.
    var feed: RSSFeed? { feeds.first { $0.id == selectedFeed } ?? feeds.first }

    func items(_ feed: RSSFeed?) -> [RSSItem] { feed.flatMap { articles[$0.id] } ?? [] }

    func unreadCount(_ id: RSSFeed.ID?) -> Int {
        guard let id else { return 0 }
        return (articles[id] ?? []).filter { !readKeys.contains($0.key) }.count
    }

    func article(in feed: RSSFeed?) -> RSSItem? {
        guard let selectedArticle else { return nil }
        return items(feed).first { $0.key == selectedArticle }
    }
}

/// What the columns can ask the reader to do.
struct RSSReaderActions {
    let selectFeed: (RSSFeed.ID) -> Void
    let selectArticle: (String) -> Void
    let markRead: (RSSItem) -> Void
    let markAllRead: (RSSFeed.ID) -> Void
    let editRule: (RSSFeed) -> Void
    let addFeed: () -> Void
    let download: (RSSItem, RSSFeed?) -> Void
}

struct RSSRuleRequest: Identifiable {
    let id = UUID()
    /// nil adds a new feed.
    let feed: RSSFeed?
}
