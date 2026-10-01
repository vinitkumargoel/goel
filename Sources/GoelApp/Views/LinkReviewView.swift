import SwiftUI
import GoelCore

/// The shared "Review N links" step: the Add sheet's multi-link paste, Paste URLs from the
/// palette, and the link grabber all end here before anything is queued.
struct LinkReviewView: View {
    @EnvironmentObject private var vm: AppViewModel

    let text: String
    /// "Showing first 500 of 812" from the grabber; nil when nothing was left out.
    var truncationNote: String?
    let back: () -> Void
    let done: () -> Void

    @State private var items: [LinkReviewItem] = []
    @State private var query = ""
    @State private var category: GrabbedLink.Category?
    @State private var folder: String?
    @State private var priority: FilePriority = .normal
    @State private var startSelection = "now"
    @State private var whenDone = WhenDone.nothing
    @State private var freeBytes: Int64?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                LinkReviewFilterBar(items: items, query: $query, category: $category)
                LinkReviewList(items: $items, visibleIDs: visibleIDs) { id in loadSize(id) }
                selectionBar
                if let truncationNote {
                    Label(truncationNote, systemImage: "info.circle")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                }
                options
            }
            .padding(18)
            Divider()
            footer
        }
        .onAppear { items = vm.reviewItems(for: text) }
        .task(id: folder) { await refreshFreeSpace() }
    }

    private var visibleIDs: [String] {
        LinkReview.visible(items, query: query, category: category).map(\.id)
    }

    private var selectionBar: some View {
        HStack {
            Button(allVisibleChecked ? L10n.t("Select None") : L10n.t("Select All")) { toggleVisible() }
            Spacer()
            Text(L10n.t("%1$d of %2$d selected", LinkReview.totals(items).count, items.count))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        HStack(alignment: .top, spacing: 12) {
            AddOptionColumn(title: L10n.t("Save to")) {
                SaveFolderPicker(folder: $folder, automaticLabel: L10n.t("Default folder rule"))
            }
            AddOptionColumn(title: L10n.t("Priority")) { PriorityPicker(priority: $priority) }
            AddOptionColumn(title: L10n.t("Start")) {
                Dropdown(selection: $startSelection, items: startOptions, width: 150,
                         accessibilityName: L10n.t("Start"))
            }
            AddOptionColumn(title: L10n.t("When done")) { WhenDonePicker(whenDone: $whenDone, width: 140) }
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("Back")) { back() }
            Spacer()
            Button(L10n.t("Cancel")) { done() }
                .keyboardShortcut(.cancelAction)
            Button(LinkReview.addTitle(LinkReview.totals(items), freeBytes: freeBytes)) { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(LinkReview.totals(items).count == 0)
        }
        .padding(14)
    }

    private var startOptions: [Dropdown<String>.Item] {
        [.option("now", L10n.t("Now"))] + ScheduledStartOption.presets.map { .option($0.id, $0.label) }
    }

    private var allVisibleChecked: Bool {
        let ids = Set(visibleIDs)
        return !ids.isEmpty && items.filter { ids.contains($0.id) }.allSatisfy(\.checked)
    }

    private func toggleVisible() {
        let ids = Set(visibleIDs)
        let target = !allVisibleChecked
        for index in items.indices where ids.contains(items[index].id) { items[index].checked = target }
    }

    private func loadSize(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].sizeRequested else { return }
        items[index].sizeRequested = true
        let item = items[index]
        Task { @MainActor in
            let size = await vm.reviewSize(for: item)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].size = size
            items[index].sizeResolved = true
        }
    }

    private func refreshFreeSpace() async {
        let path = folder ?? vm.settings.defaultSaveDirectory
        let free = await Task.detached(priority: .userInitiated) {
            DiskSpaceCheck.availableCapacity(forFolder: path)
        }.value
        if !Task.isCancelled { freeBytes = free }
    }

    private func add() {
        let startAt = ScheduledStartOption.presets.first { $0.id == startSelection }?.date()
        let options = AppViewModel.ReviewedAddOptions(
            saveDirectory: folder, priority: priority, startAt: startAt,
            whenDone: whenDone.isActionable ? whenDone : nil)
        vm.addReviewed(items.filter(\.checked), options: options)
        done()
    }
}

/// The filter box and one chip per type present.
private struct LinkReviewFilterBar: View {
    let items: [LinkReviewItem]
    @Binding var query: String
    @Binding var category: GrabbedLink.Category?

    var body: some View {
        HStack(spacing: 6) {
            TextField(L10n.t("Filter"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .accessibilityLabel(L10n.t("Filter links"))
            ReviewChip(label: L10n.t("All (%d)", items.count), active: category == nil) { category = nil }
            ForEach(LinkReview.categories(in: items), id: \.self) { kind in
                ReviewChip(label: L10n.t("%1$@ (%2$@)", kind.label,
                                         String(items.filter { $0.category == kind }.count)),
                           active: category == kind) { category = kind }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ReviewChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: Theme.TextSize.meta, weight: active ? .semibold : .regular)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
                .foregroundStyle(active ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Name / Host / Type / Size, with a badge on links already in the list.
private struct LinkReviewList: View {
    @Binding var items: [LinkReviewItem]
    let visibleIDs: [String]
    let needsSize: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleIDs, id: \.self) { id in
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        LinkReviewRow(item: $items[index])
                            .onAppear { needsSize(id) }
                    }
                }
            }
        }
        .frame(height: 240)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.hairline))
    }
}

private struct LinkReviewRow: View {
    @Binding var item: LinkReviewItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $item.checked)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(item.name)
            Text(item.name)
                .scaledFont(size: Theme.TextSize.meta)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.line)
            if let status = item.duplicateStatus { duplicateBadge(status) }
            Spacer(minLength: 8)
            Text(item.host)
                .scaledFont(size: Theme.TextSize.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .trailing)
            Text(item.category.label)
                .scaledFont(size: Theme.TextSize.micro)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(sizeText)
                .scaledFont(size: Theme.TextSize.micro)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var sizeText: String {
        if let size = item.size { return size.byteString }
        return item.sizeResolved ? "—" : "…"
    }

    private func duplicateBadge(_ status: String) -> some View {
        Text(L10n.t("In list · %@", status))
            .scaledFont(size: Theme.TextSize.micro, weight: .semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.orange)
            .help(L10n.t("Already in your list — adding it again won’t make a second copy."))
    }
}
