import SwiftUI
import GoelCore

/// The content header: what is showing and how many, the Select / Sort / Group by menus, the
/// filter chips and the Board / List switch. Every control reads and writes the view model's
/// own filter, sort and grouping, so the rail, the command palette and these chips agree.
struct DownloadsHeader: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var layout: DownloadsLayout
    @Binding var columnsRaw: String
    @Binding var density: ListDensity

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            HStack(alignment: .center, spacing: Studio.Space.sm) {
                titleBlock
                Spacer(minLength: Studio.Space.m)
                ViewThatFits(in: .horizontal) {
                    menus(labelled: true)
                    menus(labelled: false)
                }
                .layoutPriority(1)
            }
            HStack(spacing: Studio.Space.m) {
                ScrollView(.horizontal, showsIndicators: false) {
                    DownloadsFilterChips()
                        .padding(.vertical, Studio.Space.xxs)
                        .padding(.horizontal, 1)
                        .padding(.trailing, Studio.Space.xl)
                }
                // Fades the trailing edge, so chips cut off by a narrow window read as scrollable.
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Studio.Space.xl)
                    }
                }
                StudioSegmentedControl(
                    selection: $layout,
                    segments: DownloadsLayout.allCases.map { StudioSegment($0, title: $0.title, symbol: $0.symbol) },
                    accessibilityLabel: L10n.t("Layout"))
            }
        }
    }

    private var titleBlock: some View {
        let term = vm.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
            Text(vm.filters.title)
                .studioFont(.title2)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "\(vm.visibleTasks.count)")
                .studioFont(Studio.TextStyle.monoSmall.weight(600))
                .foregroundStyle(Studio.Palette.ink2)
                .padding(.horizontal, Studio.Space.cozy)
                .padding(.vertical, Studio.Space.hair)
                .background(Studio.Palette.segment, in: Capsule())
                .accessibilityLabel(vm.visibleTasks.count == 1 ? L10n.t("%d download", 1)
                                                               : L10n.t("%d downloads", vm.visibleTasks.count))
            if !term.isEmpty {
                Text(L10n.t("matching “%@”", term))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func menus(labelled: Bool) -> some View {
        HStack(spacing: Studio.Space.xxs) {
            DownloadsHeaderMenuButton(title: L10n.t("Select"), symbol: "checkmark.circle", showsTitle: labelled,
                                      accessibilityValue: L10n.t("%d selected", vm.selection.count)) {
                DownloadsHeaderMenus.selectNodes(vm)
            }
            DownloadsHeaderMenuButton(title: L10n.t("Sort"), symbol: "arrow.up.arrow.down", showsTitle: labelled,
                                      accessibilityValue: L10n.t("%1$@, %2$@", vm.sortKey.title,
                                                                 vm.sortAscending ? L10n.t("ascending")
                                                                                  : L10n.t("descending"))) {
                DownloadsHeaderMenus.sortNodes(vm)
            }
            DownloadsHeaderMenuButton(title: L10n.t("Group by"), symbol: "square.stack.3d.up", showsTitle: labelled,
                                      isActive: vm.grouping != .none,
                                      accessibilityValue: vm.grouping.title) {
                DownloadsHeaderMenus.groupNodes(vm)
            }
            if layout == .list {
                DownloadsHeaderMenuButton(title: L10n.t("Columns"), symbol: "tablecells", showsTitle: labelled,
                                          accessibilityValue: density.title) {
                    DownloadsHeaderMenus.columnNodes(columnsRaw: $columnsRaw, density: $density)
                }
            }
        }
        .fixedSize()
    }
}

/// A ghost header button that opens a Studio popover menu.
struct DownloadsHeaderMenuButton: View {
    let title: String
    let symbol: String
    var showsTitle = true
    var isActive = false
    var accessibilityValue: String = ""
    let nodes: () -> [DownloadMenuNode]

    @State private var isOpen = false

    init(title: String, symbol: String, showsTitle: Bool = true, isActive: Bool = false,
         accessibilityValue: String = "", nodes: @escaping () -> [DownloadMenuNode]) {
        self.title = title
        self.symbol = symbol
        self.showsTitle = showsTitle
        self.isActive = isActive
        self.accessibilityValue = accessibilityValue
        self.nodes = nodes
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Studio.Space.snug) {
                Image(systemName: symbol)
                if showsTitle { Text(title) }
                Image(systemName: "chevron.down")
                    .studioFont(.ui, size: 8.5, weight: 750)
                    .opacity(0.7)
            }
        }
        .buttonStyle(.studio(isOpen || isActive ? .soft : .ghost, size: .small))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.t("Activate to open the %@ menu.", L10n.midSentence(title)))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DownloadStudioMenu(nodes: nodes(), width: 240) { isOpen = false }
                .background(Studio.Palette.cardRaised)
        }
    }
}

/// The expanded rail lists every status filter; the header then drops its duplicate chips.
private struct RailShowsStatusFiltersKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var railShowsStatusFilters: Bool {
        get { self[RailShowsStatusFiltersKey.self] }
        set { self[RailShowsStatusFiltersKey.self] = newValue }
    }
}

/// The status chips with counts, then Type ▾ (or the active type as a removable chip), then the
/// active tag as a removable chip. Status, type and tag combine ("Active" + "Audio ×"); each
/// chip's count is what picking it would show with the other filters kept. While the expanded
/// rail lists the statuses, only the active status shows here, as a removable chip.
struct DownloadsFilterChips: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.railShowsStatusFilters) private var railShowsStatus
    @State private var typeMenuOpen = false

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            if railShowsStatus {
                if vm.filters.status != .all {
                    removableChip(title: vm.filters.status.accessibilityName,
                                  count: vm.visibleCountIgnoringSearch, symbol: nil) {
                        vm.filters.status = .all
                    }
                }
            } else {
                ForEach(SidebarCatalog.library + SidebarCatalog.status) { entry in
                    StudioFilterChip(entry.filter == .all ? L10n.t("All") : entry.title,
                                     count: vm.facetCount(for: entry.filter),
                                     isOn: vm.filters.isOn(entry.filter)) {
                        vm.filters = vm.filters.setting(entry.filter)
                    }
                }
                Rectangle()
                    .fill(Studio.Palette.hairlineStrong)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, Studio.Space.xxs)
                    .a11yDecorative()
            }
            typeChip
            if let tag = vm.filters.tag {
                removableChip(title: tag, count: vm.visibleCountIgnoringSearch, symbol: "tag") {
                    vm.filters.tag = nil
                }
            }
        }
    }

    @ViewBuilder
    private var typeChip: some View {
        if let type = vm.filters.type {
            removableChip(title: type.accessibilityName, count: vm.visibleCountIgnoringSearch, symbol: nil) {
                vm.filters.type = nil
            }
        } else {
            Button {
                typeMenuOpen.toggle()
            } label: {
                HStack(spacing: Studio.Space.snug) {
                    Text(L10n.t("Type"))
                    Image(systemName: "chevron.down")
                        .studioFont(.ui, size: 9, weight: 750)
                }
            }
            .buttonStyle(StudioPillButtonStyle(isOn: false))
            .accessibilityHint(L10n.t("Activate to open the %@ menu.", L10n.midSentence(L10n.t("Type"))))
            .popover(isPresented: $typeMenuOpen, arrowEdge: .bottom) {
                DownloadStudioMenu(nodes: DownloadsHeaderMenus.typeNodes(vm), width: 220) { typeMenuOpen = false }
                    .background(Studio.Palette.cardRaised)
            }
        }
    }

    /// An active filter: on, with an ✕ that removes just that filter and keeps the others.
    private func removableChip(title: String, count: Int, symbol: String?,
                               remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: Studio.Space.xs) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
                Text(verbatim: "\(count)")
                    .studioFont(.monoSmall)
                    .opacity(0.7)
                Image(systemName: "xmark")
                    .studioFont(.ui, size: 9, weight: 750)
            }
        }
        .buttonStyle(StudioPillButtonStyle(isOn: true))
        .help(L10n.t("Clear filter"))
        .accessibilityLabel(L10n.t("Clear filter"))
        .accessibilityValue(title)
    }
}
