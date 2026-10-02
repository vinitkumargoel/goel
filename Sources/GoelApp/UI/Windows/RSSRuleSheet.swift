import SwiftUI
import GoelCore

/// Add or edit a feed and its download rule. A live line says how many of the feed's current
/// articles the rule would take, with the articles below it, while you type.
struct RSSRuleSheet: View {
    let original: RSSFeed?
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = RSSReaderModel.shared
    @State private var draft: RSSFeed
    private let previewItems: [RSSItem]?

    /// `previewItems` replaces the live fetch (previews and snapshots).
    init(original: RSSFeed?, previewItems: [RSSItem]? = nil) {
        self.original = original
        self.previewItems = previewItems
        _draft = State(initialValue: original ?? RSSFeed(url: ""))
    }

    private var isValidURL: Bool {
        URL(string: draft.url.trimmingCharacters(in: .whitespaces))?.host != nil
    }

    private var episodeFilterValid: Bool {
        draft.episodeFilter.trimmingCharacters(in: .whitespaces).isEmpty
            || RSSRuleMatcher.EpisodeFilter(draft.episodeFilter) != nil
    }

    var body: some View {
        StudioSheet(title: original == nil ? L10n.t("Add Feed") : L10n.t("Rule · %@", original?.displayName ?? ""),
                    subtitle: original == nil ? L10n.t("Paste the feed’s address, then say what it should download.") : nil,
                    symbol: "dot.radiowaves.up.forward", width: 470) {
            form
            RSSRulePreview(draft: draft, previewItems: previewItems)
        } footer: {
            StudioSheetFooter(onCancel: { dismiss() }, primaryTitle: L10n.t("Save"),
                              primaryEnabled: isValidURL && episodeFilterValid, onPrimary: save) {
                if let original {
                    Button(L10n.t("Remove Feed"), role: .destructive) {
                        vm.update { $0.rssFeeds.removeAll { $0.id == original.id } }
                        dismiss()
                    }
                    .buttonStyle(.studio(.destructive, size: .small))
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            field(L10n.t("Feed URL"), text: $draft.url, prompt: "https://…/feed.xml", mono: true)
            field(L10n.t("Name"), text: $draft.name, prompt: L10n.t("Optional"))
            field(L10n.t("Must contain"), text: $draft.titlePattern, prompt: L10n.t("1080p|2160p — empty takes all"),
                  mono: true)
            field(L10n.t("Must not contain"), text: $draft.mustNotContain, prompt: L10n.t("CAM|TS"), mono: true)
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                field(L10n.t("Episodes"), text: $draft.episodeFilter, prompt: "1x2;8-10;20-", mono: true,
                      help: episodeFilterValid ? nil : L10n.t("Use season x episodes, e.g. 1x2;8-10;20-"),
                      helpTone: .bad)
                field(L10n.t("Tag"), text: $draft.tag, prompt: L10n.t("Optional"))
            }
            folderRow
            HStack(spacing: Studio.Space.xl) {
                Toggle(L10n.t("Enabled"), isOn: $draft.enabled).toggleStyle(.studioSwitch)
                Toggle(L10n.t("Add paused"), isOn: $draft.startPaused).toggleStyle(.studioSwitch)
                Spacer(minLength: 0)
            }
            .padding(.top, Studio.Space.xxs)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, mono: Bool = false,
                       help: String? = nil, helpTone: StudioTone = .neutral) -> some View {
        WindowsLabeledField(label: title, help: help, helpTone: helpTone) {
            StudioFocusedField(size: .small) { focus in
                TextField(text: text, prompt: Text(prompt).foregroundStyle(Studio.Palette.ink3)) { Text(prompt) }
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .modifier(RSSMonoFont(isMono: mono))
                    .accessibilityLabel(title)
            }
        }
    }

    private var folderRow: some View {
        WindowsLabeledField(label: L10n.t("Folder")) {
            HStack(spacing: Studio.Space.s) {
                Image(systemName: "folder")
                    .font(StudioFonts.font(.ui, size: 12, weight: 650))
                    .foregroundStyle(Studio.Palette.accent)
                    .accessibilityHidden(true)
                Text(draft.saveDirectory.isEmpty ? L10n.t("Default folder rule")
                                                 : (draft.saveDirectory as NSString).abbreviatingWithTildeInPath)
                    .studioFont(draft.saveDirectory.isEmpty ? .small : .monoBody)
                    .foregroundStyle(draft.saveDirectory.isEmpty ? Studio.Palette.ink3 : Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: Studio.Space.s)
                if !draft.saveDirectory.isEmpty {
                    Button(L10n.t("Reset")) { draft.saveDirectory = "" }
                        .buttonStyle(.studio(.ghost, size: .small))
                }
                Button(L10n.t("Choose…")) {
                    if let url = FilePicker.chooseDirectory() { draft.saveDirectory = url.path }
                }
                .buttonStyle(.studio(.secondary, size: .small))
            }
            .padding(.leading, Studio.Space.m)
            .padding(.trailing, 3)
            .padding(.vertical, 3)
            .frame(minHeight: 30)
            .modifier(StudioFieldChrome(isFocused: false, radius: Studio.Radius.small))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Folder"))
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

private struct RSSMonoFont: ViewModifier {
    let isMono: Bool

    func body(content: Content) -> some View {
        if isMono { content.studioFont(.monoBody) } else { content.studioFont(.body.size(12.5)) }
    }
}

/// Live match preview: the feed's latest articles, matches first-class, fetched once per URL.
private struct RSSRulePreview: View {
    let draft: RSSFeed
    let previewItems: [RSSItem]?
    @EnvironmentObject private var vm: AppViewModel
    @State private var items: [RSSItem] = []
    @State private var status: String?

    private var shown: [RSSItem] { previewItems ?? items }
    private var matchCount: Int { shown.filter { RSSRuleMatcher.matches(title: $0.title, feed: draft) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioNote(tone: noteTone, symbol: noteSymbol,
                       message: previewItems == nil ? (status ?? countLine) : countLine)
            if !shown.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Studio.Space.hair) {
                        ForEach(shown, id: \.key) { item in
                            let matches = RSSRuleMatcher.matches(title: item.title, feed: draft)
                            HStack(spacing: Studio.Space.s) {
                                Image(systemName: matches ? "checkmark.circle.fill" : "circle")
                                    .font(StudioFonts.font(.ui, size: 11, weight: 650))
                                    .foregroundStyle(matches ? Studio.Palette.accent : Studio.Palette.ink3)
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .studioFont(.small)
                                    .foregroundStyle(matches ? Studio.Palette.ink : Studio.Palette.ink3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(matches ? L10n.t("Matches the rule") : "")
                        }
                    }
                    .padding(.horizontal, Studio.Space.m)
                    .padding(.vertical, Studio.Space.xs)
                }
                .frame(maxHeight: 120)
                .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
                    .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
            }
        }
        .task(id: draft.url) {
            guard previewItems == nil else { return }
            await load()
        }
    }

    private var countLine: String {
        L10n.t("%1$d of %2$d current articles match", matchCount, shown.count)
    }

    private var noteTone: StudioTone {
        if status != nil && previewItems == nil { return .neutral }
        return matchCount > 0 ? .accent : .neutral
    }

    private var noteSymbol: String {
        matchCount > 0 && (status == nil || previewItems != nil) ? "checkmark" : "dot.radiowaves.up.forward"
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
