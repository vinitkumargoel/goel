import SwiftUI
import GoelCore

/// The shared "Review N links" step: the Add sheet's multi-link paste, Paste URLs from the
/// palette, and the link grabber all end here before anything is queued. Draws the whole sheet.
struct LinkReviewView: View {
    @EnvironmentObject private var vm: AppViewModel

    let title: String
    let text: String
    /// "Showing first 500 of 812" from the grabber; nil when nothing was left out.
    var truncationNote: String?
    /// Snapshot seam: rows to show instead of building them from `text`. Nil in the app.
    var seed: [LinkReviewItem]?
    let back: () -> Void
    let done: () -> Void

    @State private var items: [LinkReviewItem] = []
    @State private var query = ""
    @State private var category: GrabbedLink.Category?
    @State private var folder: String?
    @State private var priority: FilePriority = .normal
    @State private var startSelection = StartPicker.now
    @State private var whenDone = WhenDone.nothing
    @State private var freeBytes: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                LinkReviewFilterBar(items: items, query: $query, category: $category)
                LinkReviewList(items: $items, visibleIDs: visibleIDs) { id in loadSize(id) }
                if let truncationNote {
                    StudioNote(tone: .neutral, symbol: "info.circle", message: truncationNote)
                }
                options
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xl)
            footer
        }
        .onAppear { items = seed ?? vm.reviewItems(for: text) }
        .task(id: folder) { await refreshFreeSpace() }
    }

    private var visibleIDs: [String] {
        LinkReview.visible(items, query: query, category: category).map(\.id)
    }

    private var header: some View {
        AddFlowHeader(title: title, eyebrow: L10n.t("Step 2 of 2"), symbol: "checklist") {
            HStack(spacing: Studio.Space.sm) {
                Text(L10n.t("%1$d of %2$d selected", LinkReview.totals(items).count, items.count))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                Button(allVisibleChecked ? L10n.t("Select None") : L10n.t("Select All")) { toggleVisible() }
                    .buttonStyle(.studio(.ghost, size: .small))
            }
        }
    }

    private var options: some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            AddOptionColumn(title: L10n.t("Save to")) {
                SaveFolderPicker(folder: $folder, automaticLabel: L10n.t("Default folder rule"))
            }
            AddOptionColumn(title: L10n.t("Priority")) { PriorityPicker(priority: $priority) }
                .frame(width: 216)
            AddOptionColumn(title: L10n.t("Start")) { StartPicker(selection: $startSelection) }
            AddOptionColumn(title: L10n.t("When done")) { WhenDonePicker(whenDone: $whenDone, width: nil) }
        }
    }

    private var footer: some View {
        AddFlowFooter {
            Button(L10n.t("Back"), systemImage: "chevron.left") { back() }
                .buttonStyle(.studio(.ghost))
            Spacer()
            Button(L10n.t("Cancel")) { done() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.studio(.secondary))
            Button(LinkReview.addTitle(LinkReview.totals(items), freeBytes: freeBytes)) { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.studio(.primary))
                .disabled(LinkReview.totals(items).count == 0)
        }
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
        let options = AppViewModel.ReviewedAddOptions(
            saveDirectory: folder, priority: priority, startAt: StartPicker.date(for: startSelection),
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
        HStack(alignment: .top, spacing: Studio.Space.s) {
            StudioSearchField(text: $query, placeholder: L10n.t("Filter"), size: .small)
                .frame(width: 170)
                .accessibilityLabel(L10n.t("Filter links"))
            AddChipFlow {
                StudioFilterChip(L10n.t("All"), count: items.count, isOn: category == nil, size: .small) {
                    category = nil
                }
                ForEach(LinkReview.categories(in: items), id: \.self) { kind in
                    StudioFilterChip(kind.label, count: items.filter { $0.category == kind }.count,
                                     isOn: category == kind, size: .small) { category = kind }
                }
            }
            .padding(.top, 3)
        }
    }
}

/// Name and host, protocol, size and status, with a badge on links already in the list.
private struct LinkReviewList: View {
    @Binding var items: [LinkReviewItem]
    let visibleIDs: [String]
    let needsSize: (String) -> Void

    var body: some View {
        AddListWell(height: 288) {
            LazyVStack(spacing: 2) {
                ForEach(visibleIDs, id: \.self) { id in
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        LinkReviewRow(item: $items[index])
                            .onAppear { needsSize(id) }
                    }
                }
            }
        }
    }
}

private struct LinkReviewRow: View {
    @Binding var item: LinkReviewItem

    private var artKind: StudioArtKind {
        switch item.source {
        case .magnet: return .magnet
        default:
            let type = FileType.classify(fileName: item.name, isTorrent: item.source.kind == .torrent)
            return type == .other ? item.category.artKind : StudioArtKind(type)
        }
    }

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            Toggle(isOn: $item.checked) { EmptyView() }
                .toggleStyle(.studioCheckbox)
                .accessibilityLabel(item.name)
            StudioFileArtwork(kind: artKind, size: .s, isFaded: !item.checked)
            VStack(alignment: .leading, spacing: 1) {
                FileNameText(item.name, lineLimit: 1)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(item.checked ? Studio.Palette.ink : Studio.Palette.ink3)
                    .help(item.line)
                Text([item.host, item.category.label].filter { !$0.isEmpty }.joined(separator: " · "))
                    .studioFont(.tiny)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StudioKindBadge(kind: item.source.kind)
                .frame(width: 44)
            Text(sizeText)
                .studioFont(.mono)
                .foregroundStyle(item.size == nil ? Studio.Palette.ink3 : Studio.Palette.ink2)
                .frame(width: 70, alignment: .trailing)
            status
                .fixedSize()
                .frame(minWidth: 128, alignment: .trailing)
                .padding(.leading, Studio.Space.xs)
        }
        .padding(.horizontal, Studio.Space.sm)
        .padding(.vertical, Studio.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var sizeText: String {
        if let size = item.size { return size.byteString }
        return item.sizeResolved ? "—" : "…"
    }

    @ViewBuilder private var status: some View {
        if let status = item.duplicateStatus {
            StudioPill(L10n.t("In list · %@", status), tone: .warn)
                .help(L10n.t("Already in your list — adding it again won’t make a second copy."))
        } else {
            StudioPill(L10n.t("New"), tone: .good)
        }
    }
}
