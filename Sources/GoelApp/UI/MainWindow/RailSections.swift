import SwiftUI
import GoelCore

/// The filter rows the expanded rail and the Filters flyout share: Library, Status and Type.
/// Picking one leaves a server browser or the RSS reader, like ⌘1…⌘9 do.
struct RailFilterSections: View {
    @EnvironmentObject private var vm: AppViewModel
    /// Observed so the filter rows un-highlight while the RSS reader is showing.
    @ObservedObject private var rss = RSSReaderModel.shared

    @AppStorage("sidebar.typesExpanded") private var typesExpanded = true
    /// Off by default: eight type rows at zero pushed Servers below the fold of a short window.
    @AppStorage("sidebar.showEmptyTypes") private var showEmptyTypes = false

    /// Set by a flyout so a pick also closes it.
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.hair) {
            RailSectionHeader(L10n.t("Library"))
            entries(SidebarCatalog.library)
            RailSectionHeader(L10n.t("Status"))
            entries(SidebarCatalog.status)
            typesGroup
        }
    }

    private func entries(_ list: [SidebarEntry]) -> some View {
        ForEach(list) { entry in
            filterRow(entry)
        }
    }

    /// "All downloads" is on only with nothing narrowing the list; every other row is on while
    /// its own axis holds it, so "Active" and "Audio" can both be on.
    private func isOn(_ filter: SidebarFilter) -> Bool {
        filter == .all ? vm.filters.isEmpty : vm.filters.isOn(filter)
    }

    private func filterRow(_ entry: SidebarEntry) -> some View {
        let shortcut = SidebarCatalog.shortcutFilters.firstIndex(of: entry.filter).map { $0 + 1 }
        let count = vm.count(for: entry.filter)
        return RailRow(
            title: entry.title,
            symbol: entry.symbol,
            count: count,
            isAlert: entry.filter == .failed,
            isSelected: isOn(entry.filter) && vm.selectedServer == nil && !rss.isOpen,
            help: shortcut.map { ShortcutHint.help(entry.title, "⌘\($0)") } ?? entry.title,
            accessibilityValue: L10n.t("%d downloads", count),
            accessibilityHint: L10n.t("Activate to filter the list.")
        ) {
            vm.closeServerBrowser()
            vm.filter = entry.filter
            onPick()
        }
    }

    /// Collapsible, and rows at zero hide behind "Show all types" — except the one being viewed.
    @ViewBuilder
    private var typesGroup: some View {
        let shown = SidebarCatalog.types.filter { entry in
            showEmptyTypes || vm.filters.isOn(entry.filter) || vm.count(for: entry.filter) > 0
        }
        let hiddenCount = SidebarCatalog.types.count - shown.count
        disclosureHeader(L10n.t("Type"))
        if typesExpanded {
            entries(shown)
            if hiddenCount > 0 || showEmptyTypes {
                Button {
                    showEmptyTypes.toggle()
                } label: {
                    Text(showEmptyTypes ? L10n.t("Hide empty types") : L10n.t("Show all types"))
                        .studioFont(.caption.weight(600))
                        .foregroundStyle(Studio.Palette.accent)
                        .padding(.horizontal, Studio.Space.sm)
                        .padding(.vertical, Studio.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showEmptyTypes ? L10n.t("Hides types with no downloads.")
                                                  : L10n.t("Shows types with no downloads."))
            }
        }
    }

    private func disclosureHeader(_ title: String) -> some View {
        Button {
            typesExpanded.toggle()
        } label: {
            HStack(spacing: Studio.Space.xs) {
                Text(title).studioFont(.eyebrow)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(StudioFonts.font(.ui, size: 9, weight: 700))
                    .rotationEffect(.degrees(typesExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Studio.Palette.ink3)
            .padding(.horizontal, Studio.Space.sm)
            .padding(.top, Studio.Space.ml)
            .padding(.bottom, Studio.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(typesExpanded ? L10n.t("Expanded") : L10n.t("Collapsed"))
        .accessibilityHint(typesExpanded ? L10n.t("Activate to collapse.") : L10n.t("Activate to expand."))
    }
}

/// Tags, only while some row carries one: an empty heading would advertise a feature with
/// nothing in it. Tags are created per download (Add Tags…), so there is no "+" here.
struct RailTagSection: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var rss = RSSReaderModel.shared
    @AppStorage(TagColors.storageKey) private var tagColorsRaw = ""

    var showsHeader = true
    var onPick: () -> Void = {}

    var body: some View {
        let tags = ListPresentation.tagCounts(vm.tasks)
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                if showsHeader { RailSectionHeader(L10n.t("Tags")) }
                ForEach(tags, id: \.tag) { entry in
                    let filter = SidebarFilter.tag(entry.tag)
                    RailRow(
                        title: entry.tag,
                        dot: RailTagPalette.color(for: entry.tag, raw: tagColorsRaw),
                        count: entry.count,
                        isSelected: vm.filters.isOn(filter) && vm.selectedServer == nil && !rss.isOpen,
                        accessibilityValue: L10n.t("%d downloads", entry.count),
                        accessibilityHint: L10n.t("Activate to filter the list.")
                    ) {
                        vm.closeServerBrowser()
                        vm.filter = filter
                        onPick()
                    }
                    .contextMenu { tagMenu(entry.tag) }
                    .accessibilityAction(named: Text(L10n.t("Rename tag"))) { vm.promptForTagRename(entry.tag) }
                }
            }
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: String) -> some View {
        Button(L10n.t("Rename…")) { vm.promptForTagRename(tag) }
        Menu(L10n.t("Colour")) {
            ForEach(Array(RailTagPalette.names.enumerated()), id: \.offset) { slot, name in
                Button(name) { setTagColor(tag, slot: slot) }
            }
        }
        Divider()
        Button(L10n.t("Remove Tag from All Downloads"), role: .destructive) {
            vm.requestConfirm(
                title: L10n.t("Remove the tag “%@” from every download?", tag),
                message: L10n.t("The downloads stay; only the tag goes."),
                confirmTitle: L10n.t("Remove Tag"),
                destructive: true
            ) { vm.removeTagFromAll(tag) }
        }
    }

    private func setTagColor(_ tag: String, slot: Int) {
        tagColorsRaw = TagColors.encode(TagColors.setting(TagColors.decode(tagColorsRaw), tag: tag, slot: slot))
    }
}

/// "Feeds": one row that opens the RSS reader, with the total unread count.
struct RailFeedsRow: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var model = RSSReaderModel.shared

    static func unread(_ vm: AppViewModel, _ model: RSSReaderModel) -> Int {
        vm.settings.rssFeeds.reduce(0) { $0 + model.unreadCount($1.id) }
    }

    var body: some View {
        let unread = Self.unread(vm, model)
        RailRow(title: L10n.t("RSS"), symbol: "dot.radiowaves.up.forward",
                count: unread > 0 ? unread : nil, isSelected: model.isOpen,
                help: L10n.t("RSS feeds"),
                accessibilityValue: L10n.t("%d unread", unread)) {
            vm.closeServerBrowser()
            model.open()
        }
        .accessibilityLabel(L10n.t("RSS feeds"))
    }
}

/// "Converting": shows or hides the conversion cards. Must stay its own view observing the
/// center: nested observables do not propagate updates. Kept while finished or failed cards
/// remain, so a hidden dock can always be shown again.
struct RailMediaSection: View {
    @ObservedObject var center: MediaJobCenter
    var showsHeader = true

    var body: some View {
        if !center.jobs.isEmpty {
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                if showsHeader { RailSectionHeader(L10n.t("Media")) }
                RailRow(
                    title: L10n.t("Converting"),
                    symbol: "arrow.left.arrow.right",
                    count: center.liveCount,
                    help: center.isDockHidden
                        ? L10n.t("Show the conversion cards") : L10n.t("Hide the conversion cards"),
                    accessibilityValue: center.liveCount == 1
                        ? L10n.t("%d media job in progress", center.liveCount)
                        : L10n.t("%d media jobs in progress", center.liveCount),
                    accessibilityHint: center.isDockHidden ? L10n.t("Activate to show the conversion cards.")
                                                           : L10n.t("Activate to hide the conversion cards.")
                ) {
                    center.isDockHidden.toggle()
                } trailing: {
                    Image(systemName: center.isDockHidden ? "eye.slash" : "eye")
                        .font(StudioFonts.font(.ui, size: 11, weight: 600))
                        .foregroundStyle(Studio.Palette.ink3)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
