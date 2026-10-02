import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// Finished downloads, in their own resizable window: a timeline grouped by age with artwork,
/// filterable by type, sortable by date or size. Click selects (⌘/⇧ to extend), double-click
/// opens, and a row drags straight out to Finder or another app.
struct HistoryView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var items: [HistoryPresentation.Item]?
    @State private var search = ""
    @State private var typeFilter: FileType?
    @AppStorage("history.sort") private var sort: HistoryPresentation.Sort = .date
    @State private var selection: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var confirmingClear = false
    @FocusState private var listFocused: Bool
    @Environment(\.undoManager) private var undoManager

    private let loadsFromStore: Bool

    /// `items` is for previews and snapshots; the app passes nothing and the window loads them.
    init(items: [HistoryPresentation.Item]? = nil, search: String = "", selection: Set<UUID> = []) {
        _items = State(initialValue: items)
        _search = State(initialValue: search)
        _selection = State(initialValue: selection)
        loadsFromStore = items == nil
    }

    private var visible: [HistoryPresentation.Item] {
        HistoryPresentation.filtered(items ?? [], query: search, type: typeFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
            footer
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 380, idealHeight: 560)
        .studioWindowBackground()
        // History's own toasts (removed, copied, exported) appear here, not only in the main window.
        .overlay(alignment: .bottom) { ToastOverlay(queue: vm.toasts, bottomPadding: 24) }
        // Re-reads when a download finishes or an entry changes, so an open window stays current.
        .task(id: vm.historyRevision) {
            guard loadsFromStore else { return }
            await load()
        }
    }

    // MARK: - Loading

    private func load() async {
        let entries = await vm.fetchHistory()
        // Off the main actor: one stat per entry, once, instead of once per row per redraw.
        items = await Task.detached(priority: .userInitiated) {
            HistoryPresentation.items(entries) { FileManager.default.fileExists(atPath: $0) }
        }.value
    }

    // MARK: - Chrome

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            HStack(spacing: Studio.Space.s) {
                StudioSearchField(text: $search, placeholder: L10n.t("Search name or link"), size: .small)
                    .frame(minWidth: 180, maxWidth: 360)
                    .accessibilityLabel(L10n.t("Search history by name or link"))
                Spacer(minLength: Studio.Space.s)
                StudioSegmentedControl(
                    selection: $sort,
                    segments: HistoryPresentation.Sort.allCases.map {
                        StudioSegment($0, title: L10n.t("By %@", $0.title))
                    },
                    size: .small, accessibilityLabel: L10n.t("Sort by"))
                Button(L10n.t("Export CSV…"), systemImage: "square.and.arrow.up") { exportCSV() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .disabled(visible.isEmpty)
                // A local dialog: the shared confirm is drawn on the main window, not this one.
                Button(L10n.t("Clear History…"), role: .destructive) { confirmingClear = true }
                    .buttonStyle(.studio(.destructive, size: .small))
                    .disabled((items ?? []).isEmpty)
                    .confirmationDialog(L10n.t("Clear the download history?"), isPresented: $confirmingClear) {
                        Button(L10n.t("Clear History"), role: .destructive) {
                            vm.clearHistory()
                            items = []
                            selection = []
                        }
                        Button(L10n.t("Cancel"), role: .cancel) { }
                    } message: {
                        Text(L10n.t("This removes every archived entry. Files on disk are not touched."))
                    }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Studio.Space.xs) {
                    StudioFilterChip(L10n.t("All"), isOn: typeFilter == nil, size: .small) { typeFilter = nil }
                    ForEach(HistoryPresentation.types(in: items ?? []), id: \.self) { type in
                        StudioFilterChip(type.accessibilityName, isOn: typeFilter == type, size: .small) {
                            typeFilter = typeFilter == type ? nil : type
                        }
                    }
                }
                .padding(.vertical, Studio.Space.hair)
            }
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, Studio.Space.m)
        .padding(.bottom, Studio.Space.sm)
    }

    private var footer: some View {
        let picked = selectedItems
        return HStack(spacing: Studio.Space.s) {
            if picked.count > 1 {
                Text(L10n.t("%d selected", picked.count))
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                Button(L10n.t("Download %d Again", picked.count), systemImage: "arrow.down.circle") {
                    picked.forEach { vm.redownload($0.entry) }
                }
                .buttonStyle(.studio(.soft, size: .small))
                Button(L10n.t("Copy %d Links", picked.count), systemImage: "link") { copyLinks(picked) }
                    .buttonStyle(.studio(.ghost, size: .small))
                Button(L10n.t("Remove %d from History", picked.count), systemImage: "trash", role: .destructive) {
                    remove(picked)
                }
                .buttonStyle(.studio(.destructive, size: .small))
                Spacer(minLength: Studio.Space.s)
                Button(L10n.t("Deselect")) { selection = [] }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .keyboardShortcut(.cancelAction)
            } else {
                Text(HistoryPresentation.footer(visible))
                    .studioFont(.small)
                    .monospacedDigit()
                    .foregroundStyle(Studio.Palette.ink2)
                Spacer(minLength: Studio.Space.s)
                Text(L10n.t("Double-click to open · drag a row out to use the file"))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Studio.Space.xl)
        .frame(minHeight: 44)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if let items {
            if items.isEmpty {
                StudioEmptyState(symbol: "clock.arrow.circlepath", title: L10n.t("No history yet"),
                                 message: L10n.t("Nothing here yet — finished downloads are archived automatically."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: L10n.t("No matches"),
                                 message: L10n.t("Nothing in your history matches this search and filter.")) {
                    Button(L10n.t("Clear Search and Filter")) {
                        search = ""
                        typeFilter = nil
                    }
                    .buttonStyle(.studio(.secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.t("Loading history"))
        }
    }

    private var list: some View {
        let sections = HistoryPresentation.sections(visible, sort: sort, now: Date())
        let ordered = sections.flatMap(\.items)
        return GeometryReader { proxy in
            HStack(alignment: .top, spacing: Studio.Space.xl) {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Studio.Space.xs) {
                            ForEach(sections, id: \.section) { group in
                                WindowsEyebrow(L10n.t("%1$@ · %2$@", group.section.title, String(group.items.count)))
                                    .padding(.horizontal, Studio.Space.xxs)
                                    .padding(.top, group.section == sections.first?.section
                                             ? Studio.Space.xxs : Studio.Space.m)
                                    .padding(.bottom, Studio.Space.xxs)
                                ForEach(group.items) { item in
                                    row(item, ordered: ordered)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(.horizontal, Studio.Space.xl)
                        .padding(.vertical, Studio.Space.s)
                    }
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { step(1, in: ordered, scroller: scroller) }
                    .onKeyPress(.upArrow) { step(-1, in: ordered, scroller: scroller) }
                    .onKeyPress(.return) {
                        guard !selection.isEmpty else { return .ignored }
                        selectedItems.forEach(open)
                        return .handled
                    }
                    .background {
                        Button(L10n.t("Select All")) { selection = Set(ordered.map(\.id)) }
                            .keyboardShortcut("a", modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
                }
                if proxy.size.width >= 900 {
                    HistorySummaryCard(items: visible)
                        .frame(width: 280)
                        .padding(.trailing, Studio.Space.xl)
                        .padding(.top, Studio.Space.s)
                }
            }
        }
    }

    private func row(_ item: HistoryPresentation.Item, ordered: [HistoryPresentation.Item]) -> some View {
        HistoryRow(item: item, isSelected: selection.contains(item.id),
                   onOpen: { open(item) }, onReveal: { reveal(item) }, onLocate: { locate(item) },
                   onRedownload: { vm.redownload(item.entry) },
                   onCopyLink: { vm.copyToPasteboard(item.entry.locator) },
                   onRemove: { remove([item]) })
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(item) }
            .onTapGesture { click(item, ordered: ordered) }
            .onDrag { dragProvider(item) }
            .contextMenu { menu(for: item) }
    }

    /// The context menu acts on the whole selection when the clicked row is part of it.
    @ViewBuilder
    private func menu(for clicked: HistoryPresentation.Item) -> some View {
        let picked = selection.contains(clicked.id) ? selectedItems : [clicked]
        if let one = picked.first, picked.count == 1 {
            Button(L10n.t("Open")) { open(one) }.disabled(!one.exists)
            Button(L10n.t("Show in Finder")) { reveal(one) }.disabled(!one.exists)
            if !one.exists { Button(L10n.t("Locate…")) { locate(one) } }
            Divider()
            Button(L10n.t("Download Again")) { vm.redownload(one.entry) }
            Button(L10n.t("Copy Link")) { vm.copyToPasteboard(one.entry.locator) }
            Divider()
            Button(L10n.t("Remove from History"), role: .destructive) { remove([one]) }
        } else if !picked.isEmpty {
            Button(L10n.t("Download %d Again", picked.count)) { picked.forEach { vm.redownload($0.entry) } }
            Button(L10n.t("Copy %d Links", picked.count)) { copyLinks(picked) }
            Divider()
            Button(L10n.t("Remove %d from History", picked.count), role: .destructive) { remove(picked) }
        }
    }

    // MARK: - Selection

    private var selectedItems: [HistoryPresentation.Item] {
        HistoryPresentation.sections(visible, sort: sort, now: Date())
            .flatMap(\.items)
            .filter { selection.contains($0.id) }
    }

    private func click(_ item: HistoryPresentation.Item, ordered: [HistoryPresentation.Item]) {
        listFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let from = ordered.firstIndex(where: { $0.id == anchor }),
                  let to = ordered.firstIndex(where: { $0.id == item.id }) {
            selection = Set(ordered[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
    }

    private func step(_ delta: Int, in ordered: [HistoryPresentation.Item],
                      scroller: ScrollViewProxy) -> KeyPress.Result {
        guard !ordered.isEmpty else { return .ignored }
        let current = ordered.lastIndex { selection.contains($0.id) }
        let next = current.map { min(max($0 + delta, 0), ordered.count - 1) } ?? (delta > 0 ? 0 : ordered.count - 1)
        selection = [ordered[next].id]
        selectionAnchor = ordered[next].id
        scroller.scrollTo(ordered[next].id)
        return .handled
    }

    // MARK: - Actions

    private func open(_ item: HistoryPresentation.Item) {
        guard item.exists else { locate(item); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.entry.savePath))
    }

    private func reveal(_ item: HistoryPresentation.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.entry.savePath)])
    }

    private func copyLinks(_ picked: [HistoryPresentation.Item]) {
        vm.copyToPasteboard(picked.map(\.entry.locator).joined(separator: "\n"))
    }

    private func dragProvider(_ item: HistoryPresentation.Item) -> NSItemProvider {
        guard item.exists else { return NSItemProvider(object: item.entry.locator as NSString) }
        return NSItemProvider(contentsOf: URL(fileURLWithPath: item.entry.savePath))
            ?? NSItemProvider(object: item.entry.locator as NSString)
    }

    /// The file was moved or renamed by hand: point the entry at it again.
    private func locate(_ item: HistoryPresentation.Item) {
        guard let url = FilePicker.openFile(message: L10n.t("Where is “%@” now?", item.entry.name)) else { return }
        vm.relocateHistoryEntry(item.entry, to: url.path)
        var moved = item.entry
        moved.savePath = url.path
        let replacement = HistoryPresentation.Item(entry: moved, type: item.type, exists: true)
        items = items?.map { $0.id == item.id ? replacement : $0 }
    }

    /// One batch: a single write, a single toast with Undo (also Edit ▸ Undo in this window).
    private func remove(_ picked: [HistoryPresentation.Item]) {
        let ids = Set(picked.map(\.id))
        vm.removeHistoryEntries(picked.map(\.entry), undoManager: undoManager)
        items?.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    private func exportCSV() {
        guard let url = FilePicker.save(name: "GoelDownloader-history.csv", type: .commaSeparatedText) else { return }
        vm.exportHistoryCSV(visible.map(\.entry), to: url)
    }
}
