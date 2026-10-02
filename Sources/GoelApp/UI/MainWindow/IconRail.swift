import SwiftUI
import AppKit
import GoelCore

/// The icon rail that replaces the sidebar: 68 pt of glyphs with badges, or 212 pt with labels
/// and every list inline (⌃⌘S, `vm.sidebarVisible`). Collapsed, the long lists (filters, tags,
/// servers) open in a flyout beside the rail. Everything the old sidebar offered stays reachable.
struct IconRail: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject private var rss = RSSReaderModel.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.mainWindowPreview) private var preview

    let isExpanded: Bool
    @Binding var flyout: RailFlyout?

    static let collapsedWidth: CGFloat = 68
    static let expandedWidth: CGFloat = 212

    var body: some View {
        Group {
            if isExpanded { expanded } else { collapsed }
        }
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .frame(maxHeight: .infinity)
        .studioRailBackground()
        .overlay(alignment: .trailing) {
            Rectangle().fill(Studio.Palette.hairline).frame(width: 1).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Library sidebar"))
        // The status probe is unauthenticated TCP + DNS only — it must never carry credentials.
        .task(id: preview == nil) {
            guard preview == nil else { return }
            await vm.refreshServerStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppViewModel.serverStatusRefreshSeconds * 1_000_000_000)
                if NSApplication.shared.isActive { await vm.refreshServerStatuses() }
            }
        }
        .onChange(of: vm.servers.map(\.id)) {
            guard preview == nil else { return }
            Task { await vm.refreshServerStatuses() }
        }
    }

    // MARK: Collapsed

    private var listShowing: Bool { vm.selectedServer == nil && !rss.isOpen }

    /// A short window scrolls the glyphs instead of clipping Settings off the bottom.
    private var collapsed: some View {
        ViewThatFits(in: .vertical) {
            collapsedColumn(pinsBottom: true)
            ScrollView { collapsedColumn(pinsBottom: false) }
                .scrollIndicators(.never)
        }
    }

    private func collapsedColumn(pinsBottom: Bool) -> some View {
        VStack(spacing: Studio.Space.xxs) {
            StudioRailItem(symbol: "rectangle.3.group", title: L10n.t("All downloads"),
                           badge: vm.count(for: .active),
                           isSelected: listShowing && vm.filter == .all && flyout == nil,
                           shortcut: shortcut(for: .all)) {
                pick(.all)
            }
            StudioRailItem(symbol: "exclamationmark.triangle", title: L10n.t("Needs you"),
                           badge: vm.count(for: .failed), badgeTone: .bad,
                           isSelected: listShowing && vm.filter == .failed && flyout == nil,
                           shortcut: shortcut(for: .failed)) {
                pick(.failed)
            }
            StudioRailItem(symbol: "line.3.horizontal.decrease", title: L10n.t("Filters"),
                           isSelected: flyout == .filters || (flyout == nil && listShowing && isOtherFilter)) {
                toggle(.filters)
            }
            if !ListPresentation.tagCounts(vm.tasks).isEmpty {
                StudioRailItem(symbol: "tag", title: L10n.t("Tags"),
                               isSelected: flyout == .tags || (flyout == nil && listShowing && isTagFilter)) {
                    toggle(.tags)
                }
            }
            StudioRailItem(symbol: "server.rack", title: L10n.t("Servers"),
                           badge: vm.sftpTransfers.filter(\.isActive).count,
                           isSelected: flyout == .servers || (flyout == nil && vm.selectedServer != nil)) {
                toggle(.servers)
            }
            StudioRailItem(symbol: "dot.radiowaves.up.forward", title: L10n.t("RSS feeds"),
                           badge: RailFeedsRow.unread(vm, rss),
                           isSelected: flyout == nil && rss.isOpen) {
                flyout = nil
                vm.closeServerBrowser()
                rss.open()
            }
            RailMediaItem(center: vm.mediaJobs)
            StudioRailSeparator()
            utilityItems(expanded: false)
            if pinsBottom {
                Spacer(minLength: Studio.Space.s)
            } else {
                StudioRailSeparator()
            }
            bottomItems(expanded: false)
        }
        .padding(.top, Studio.Space.sm)
        .padding(.bottom, Studio.Space.ml)
    }

    private var isTagFilter: Bool {
        if case .tag = vm.filter { return true }
        return false
    }

    /// Status and type filters live in the Filters flyout (All and Failed have their own items).
    private var isOtherFilter: Bool {
        vm.filter != .all && vm.filter != .failed && !isTagFilter
    }

    private func shortcut(for filter: SidebarFilter) -> String? {
        SidebarCatalog.shortcutFilters.firstIndex(of: filter).map { "⌘\($0 + 1)" }
    }

    private func pick(_ filter: SidebarFilter) {
        flyout = nil
        vm.closeServerBrowser()
        vm.filter = filter
    }

    private func toggle(_ kind: RailFlyout) {
        flyout = flyout == kind ? nil : kind
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    RailFilterSections()
                    RailTagSection()
                    RailMediaSection(center: vm.mediaJobs)
                    RailServerSection()
                    RailSectionHeader(L10n.t("Feeds"))
                    RailFeedsRow()
                    RailSectionHeader(L10n.t("Activity"))
                    utilityRows
                }
                .padding(.horizontal, Studio.Space.sm)
                .padding(.bottom, Studio.Space.sm)
            }
            .scrollIndicators(.never)
            VStack(spacing: 2) {
                StudioRailSeparator(isExpanded: true)
                bottomItems(expanded: true)
            }
            .padding(.horizontal, Studio.Space.sm)
            .padding(.bottom, Studio.Space.ml)
        }
    }

    /// History and Statistics as list rows in the expanded rail, so the pinned foot stays short.
    @ViewBuilder
    private var utilityRows: some View {
        RailRow(title: L10n.t("History"), symbol: "clock.arrow.circlepath",
                help: ShortcutHint.help(L10n.t("History"), "⇧⌘Y")) {
            openWindow(id: MainWindowID.history)
        }
        RailRow(title: L10n.t("Statistics"), symbol: "chart.bar",
                help: ShortcutHint.help(L10n.t("Statistics"), "⌘Y")) {
            vm.isStatsPresented = true
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func utilityItems(expanded: Bool) -> some View {
        StudioRailItem(symbol: "clock.arrow.circlepath", title: L10n.t("History"),
                       isExpanded: expanded, shortcut: "⇧⌘Y") {
            flyout = nil
            openWindow(id: MainWindowID.history)
        }
        StudioRailItem(symbol: "chart.bar", title: L10n.t("Statistics"),
                       isExpanded: expanded, shortcut: "⌘Y") {
            flyout = nil
            vm.isStatsPresented = true
        }
    }

    @ViewBuilder
    private func bottomItems(expanded: Bool) -> some View {
        StudioRailItem(symbol: "basket", title: L10n.t("Drop Basket"), isExpanded: expanded, shortcut: "⇧⌘B") {
            flyout = nil
            DropBasketController.shared.toggle()
        }
        StudioRailItem(symbol: "slider.horizontal.3", title: L10n.t("Settings"), isExpanded: expanded, shortcut: "⌘,") {
            flyout = nil
            openSettings()
        }
        StudioRailItem(symbol: "sidebar.left",
                       title: expanded ? L10n.t("Collapse sidebar") : L10n.t("Expand sidebar"),
                       isExpanded: expanded, shortcut: "⌃⌘S") {
            flyout = nil
            // ⌃⌘S is bound once, in View ▸ Toggle Sidebar.
            vm.sidebarVisible.toggle()
        }
        .accessibilityValue(expanded ? L10n.t("Shown") : L10n.t("Hidden"))
    }
}

/// The collapsed rail's Converting item. Its own view so it observes the job center.
private struct RailMediaItem: View {
    @ObservedObject var center: MediaJobCenter

    var body: some View {
        if !center.jobs.isEmpty {
            StudioRailItem(symbol: "arrow.left.arrow.right", title: L10n.t("Converting"),
                           badge: center.liveCount,
                           isSelected: !center.isDockHidden) {
                center.isDockHidden.toggle()
            }
            .help(center.isDockHidden ? L10n.t("Show the conversion cards") : L10n.t("Hide the conversion cards"))
            .accessibilityValue(center.liveCount == 1
                                ? L10n.t("%d media job in progress", center.liveCount)
                                : L10n.t("%d media jobs in progress", center.liveCount))
        }
    }
}
