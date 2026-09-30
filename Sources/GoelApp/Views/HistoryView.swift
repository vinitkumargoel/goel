import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// Finished downloads, in their own resizable window: grouped by age, filterable by type,
/// double-click opens, and a row drags straight out to Finder or another app.
struct HistoryView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var items: [HistoryPresentation.Item]?
    @State private var search = ""
    @State private var typeFilter: FileType?
    @AppStorage("history.sort") private var sort: HistoryPresentation.Sort = .date
    @State private var selection: Set<UUID> = []
    @State private var confirmingClear = false

    private var visible: [HistoryPresentation.Item] {
        HistoryPresentation.filtered(items ?? [], query: search, type: typeFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 700, minHeight: 360, idealHeight: 520)
        // Re-reads when a download finishes or an entry changes, so an open window stays current.
        .task(id: vm.historyRevision) { await load() }
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

    private var filterBar: some View {
        HStack(spacing: Theme.Space.s) {
            TextField(L10n.t("Search name or link"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)
                .accessibilityLabel(L10n.t("Search history by name or link"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    chip(L10n.t("All"), selected: typeFilter == nil) { typeFilter = nil }
                    ForEach(HistoryPresentation.types(in: items ?? []), id: \.self) { type in
                        chip(type.accessibilityName, symbol: type.symbol, selected: typeFilter == type) {
                            typeFilter = typeFilter == type ? nil : type
                        }
                    }
                }
            }
            Picker(L10n.t("Sort by"), selection: $sort) {
                ForEach(HistoryPresentation.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private func chip(_ title: String, symbol: String? = nil, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if let symbol { Image(systemName: symbol).a11yDecorative() }
                Text(title)
            }
            .scaledFont(size: Theme.TextSize.meta, weight: selected ? .semibold : .regular)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 3)
            .background(selected ? Theme.accent.opacity(0.16) : Theme.fillRest, in: Capsule())
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Text(HistoryPresentation.footer(visible))
                .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Export CSV…")) { exportCSV() }
                .disabled(visible.isEmpty)
            // A local dialog: the shared confirm is drawn on the main window, not this one.
            Button(L10n.t("Clear History…"), role: .destructive) { confirmingClear = true }
                .disabled((items ?? []).isEmpty)
                .confirmationDialog(L10n.t("Clear the download history?"), isPresented: $confirmingClear) {
                    Button(L10n.t("Clear History"), role: .destructive) {
                        vm.clearHistory()
                        items = []
                    }
                    Button(L10n.t("Cancel"), role: .cancel) { }
                } message: {
                    Text(L10n.t("This removes every archived entry. Files on disk are not touched."))
                }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if let items {
            if items.isEmpty {
                EmptyStateView(systemImage: "clock.arrow.circlepath",
                               title: L10n.t("No history yet"),
                               subtitle: L10n.t("Nothing here yet — finished downloads are archived automatically."))
            } else if visible.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass", title: L10n.t("No matches"),
                               actionTitle: L10n.t("Clear search and filter")) {
                    search = ""
                    typeFilter = nil
                }
            } else {
                list
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.t("Loading history"))
        }
    }

    private var list: some View {
        let sections = HistoryPresentation.sections(visible, sort: sort, now: Date())
        return List(selection: $selection) {
            ForEach(sections, id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.items) { item in
                        HistoryRow(item: item, locate: { locate(item) }, remove: { remove(item) })
                            .tag(item.id)
                            .onDrag { dragProvider(item) }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            ids.compactMap(item(for:)).forEach(open)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let picked = ids.compactMap(item(for:))
        if let one = picked.first, picked.count == 1 {
            Button(L10n.t("Open")) { open(one) }.disabled(!one.exists)
            Button(L10n.t("Show in Finder")) { reveal(one) }.disabled(!one.exists)
            if !one.exists { Button(L10n.t("Locate…")) { locate(one) } }
            Divider()
            Button(L10n.t("Download Again")) { vm.redownload(one.entry) }
            Button(L10n.t("Copy Link")) { vm.copyToPasteboard(one.entry.locator) }
            Divider()
            Button(L10n.t("Remove from History"), role: .destructive) { remove(one) }
        } else if !picked.isEmpty {
            Button(L10n.t("Download %d Again", picked.count)) { picked.forEach { vm.redownload($0.entry) } }
            Button(L10n.t("Copy %d Links", picked.count)) {
                vm.copyToPasteboard(picked.map(\.entry.locator).joined(separator: "\n"))
            }
            Divider()
            Button(L10n.t("Remove %d from History", picked.count), role: .destructive) { picked.forEach(remove) }
        }
    }

    // MARK: - Actions

    private func item(for id: UUID) -> HistoryPresentation.Item? {
        items?.first { $0.id == id }
    }

    private func open(_ item: HistoryPresentation.Item) {
        guard item.exists else { locate(item); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.entry.savePath))
    }

    private func reveal(_ item: HistoryPresentation.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.entry.savePath)])
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

    private func remove(_ item: HistoryPresentation.Item) {
        vm.deleteHistoryEntry(item.id)
        items?.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    private func exportCSV() {
        guard let url = FilePicker.save(name: "GoelDownloader-history.csv", type: .commaSeparatedText) else { return }
        vm.exportHistoryCSV(visible.map(\.entry), to: url)
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var vm: AppViewModel
    let item: HistoryPresentation.Item
    let locate: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            FileTypeIcon(type: item.type, size: 24)
                .opacity(item.exists ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.name)
                    .scaledFont(size: Theme.TextSize.body, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(item.exists ? Color.primary : Color.secondary)
            .a11yGroup(label: item.entry.name, value: spokenValue)
            Spacer(minLength: Theme.Space.m)
            if !item.exists {
                Button(L10n.t("Locate…"), action: locate)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.t("Locate “%@”", item.entry.name))
            }
            IconButton(symbol: "arrow.down.circle", help: L10n.t("Download again"), size: 13,
                       spokenLabel: L10n.t("Download “%@” again", item.entry.name)) {
                vm.redownload(item.entry)
            }
            IconButton(symbol: "trash", help: L10n.t("Remove entry"), size: 13,
                       spokenLabel: L10n.t("Remove “%@” from history", item.entry.name), action: remove)
        }
        .padding(.vertical, 3)
        .help(item.exists ? item.entry.savePath : L10n.t("The file is no longer at %@", item.entry.savePath))
    }

    private var subtitle: String {
        let when = item.entry.completedAt.formatted(date: .abbreviated, time: .shortened)
        let size = item.entry.totalBytes.map { " · \($0.byteString)" } ?? ""
        let missing = item.exists ? "" : " · " + L10n.t("Missing")
        return when + size + missing
    }

    private var spokenValue: String {
        A11y.sentence(item.entry.completedAt.formatted(date: .abbreviated, time: .shortened),
                      item.entry.totalBytes.map(A11y.bytes),
                      item.exists ? nil : L10n.t("File missing"))
    }
}

struct ScheduledStartOption: Identifiable {
    let id: String
    let label: String
    let date: () -> Date

    static var presets: [ScheduledStartOption] {
        [
            ScheduledStartOption(id: "1h", label: L10n.t("In 1 Hour")) {
                Date().addingTimeInterval(3600)
            },
            ScheduledStartOption(id: "4h", label: L10n.t("In 4 Hours")) {
                Date().addingTimeInterval(4 * 3600)
            },
            ScheduledStartOption(id: "night", label: L10n.t("Tonight at 2 AM")) { Self.next(hour: 2) },
            ScheduledStartOption(id: "morning", label: L10n.t("Tomorrow at 8 AM")) { Self.next(hour: 8) },
        ]
    }

    private static func next(hour: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        let candidate = calendar.date(from: components) ?? now
        return candidate > now
            ? candidate
            : calendar.date(byAdding: .day, value: 1, to: candidate) ?? now
    }
}
