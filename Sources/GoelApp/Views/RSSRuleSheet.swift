import SwiftUI
import GoelCore

/// Add or edit a feed and its download rule, with the feed's current articles below and the
/// ones the rule would take highlighted as you type.
struct RSSRuleSheet: View {
    let original: RSSFeed?
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = RSSReaderModel.shared
    @State private var draft = RSSFeed(url: "")

    private var isValidURL: Bool {
        URL(string: draft.url.trimmingCharacters(in: .whitespaces))?.host != nil
    }

    private var episodeFilterValid: Bool {
        draft.episodeFilter.trimmingCharacters(in: .whitespaces).isEmpty
            || RSSRuleMatcher.EpisodeFilter(draft.episodeFilter) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(original == nil ? L10n.t("Add Feed") : L10n.t("Edit Rule"))
                .scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
                .padding([.horizontal, .top], 18)
            form.padding(18)
            Divider()
            RSSRulePreview(draft: draft)
                .frame(height: 180)
            Divider()
            footer.padding(14)
        }
        .frame(width: 560)
        .onAppear { if let original { draft = original } }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row(L10n.t("Feed URL"), text: $draft.url, prompt: "https://…/feed.xml")
            row(L10n.t("Name"), text: $draft.name, prompt: L10n.t("Optional"))
            row(L10n.t("Must contain"), text: $draft.titlePattern, prompt: L10n.t("1080p|2160p — empty takes all"))
            row(L10n.t("Must not contain"), text: $draft.mustNotContain, prompt: L10n.t("CAM|TS"))
            row(L10n.t("Episodes"), text: $draft.episodeFilter, prompt: "1x2;8-10;20-")
            if !episodeFilterValid {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(L10n.t("Use season x episodes, e.g. 1x2;8-10;20-"))
                        .scaledFont(size: Theme.TextSize.caption).foregroundStyle(Theme.red)
                }
            }
            folderRow
            row(L10n.t("Tag"), text: $draft.tag, prompt: L10n.t("Optional"))
            GridRow {
                Text(L10n.t("Options")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Toggle(L10n.t("Enabled"), isOn: $draft.enabled)
                    Toggle(L10n.t("Add paused"), isOn: $draft.startPaused)
                }
            }
        }
    }

    private func row(_ title: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(title).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private var folderRow: some View {
        GridRow {
            Text(L10n.t("Folder")).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            HStack {
                Text(draft.saveDirectory.isEmpty ? L10n.t("Default folder rule")
                                                 : (draft.saveDirectory as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if !draft.saveDirectory.isEmpty {
                    Button(L10n.t("Reset")) { draft.saveDirectory = "" }.buttonStyle(.link)
                }
                Button(L10n.t("Choose…")) {
                    if let url = FilePicker.chooseDirectory() { draft.saveDirectory = url.path }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let original {
                Button(L10n.t("Remove Feed"), role: .destructive) {
                    vm.update { $0.rssFeeds.removeAll { $0.id == original.id } }
                    dismiss()
                }
            }
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L10n.t("Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidURL || !episodeFilterValid)
        }
    }

    private func save() {
        var edited = draft
        edited.url = edited.url.trimmingCharacters(in: .whitespaces)
        let feed = edited
        vm.update { settings in
            if let index = settings.rssFeeds.firstIndex(where: { $0.id == feed.id }) {
                settings.rssFeeds[index] = feed
            } else {
                settings.rssFeeds.append(feed)
            }
        }
        model.open(feed: feed.id)
        dismiss()
    }
}

/// Live match preview: the feed's latest articles, matches first-class, fetched once per URL.
private struct RSSRulePreview: View {
    let draft: RSSFeed
    @EnvironmentObject private var vm: AppViewModel
    @State private var items: [RSSItem] = []
    @State private var status: String?

    private var matchCount: Int { items.filter { RSSRuleMatcher.matches(title: $0.title, feed: draft) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(status ?? L10n.t("%1$d of %2$d current articles match", matchCount, items.count))
                .scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 6)
            List(items, id: \.key) { item in
                RSSArticleRow(item: item, matches: RSSRuleMatcher.matches(title: item.title, feed: draft), unread: false)
                    .opacity(RSSRuleMatcher.matches(title: item.title, feed: draft) ? 1 : 0.55)
            }
            .listStyle(.plain)
        }
        .task(id: draft.url) { await load() }
    }

    private func load() async {
        let address = draft.url.trimmingCharacters(in: .whitespaces)
        guard URL(string: address)?.host != nil else {
            items = []
            status = L10n.t("Enter a feed URL to preview its articles")
            return
        }
        // Debounce typing: only fetch once the address has settled.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        status = L10n.t("Loading…")
        do {
            items = try await vm.manager.fetchFeedItems(address)
            status = nil
        } catch {
            items = []
            status = L10n.t("Couldn’t load the feed — %@", error.localizedDescription)
        }
    }
}
