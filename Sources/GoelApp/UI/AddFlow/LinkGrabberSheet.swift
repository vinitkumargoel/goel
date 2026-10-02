import SwiftUI
import AppKit
import GoelCore

/// Grab links from a page: fetch it, list every file it links to by type, tick some, then hand
/// them to the shared review step. Presented by RootView.
struct LinkGrabberSheet: View {
    /// Snapshot seam: the sheet's state at its first frame. Nil in the app.
    struct Seed {
        var pageText = ""
        var isFetching = false
        var fetchError: String?
        var links: [GrabbedLink] = []
        var selected: Set<String> = []
        var categoryFilter: GrabbedLink.Category?
        var pastedFromClipboard = false
        var totalFound = 0
        var reviewText: String?
        var reviewItems: [LinkReviewItem]?
    }

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageText: String
    @State private var isFetching: Bool
    @State private var fetchError: String?
    @State private var links: [GrabbedLink]
    @State private var selected: Set<String>
    @State private var categoryFilter: GrabbedLink.Category?
    @State private var pastedFromClipboard: Bool
    /// What the prefill put in the field; typing anything else retires the "Pasted" note.
    @State private var clipboardPrefill: String?
    /// Every link the page had; ``links`` keeps the first ``LinkExtractor/displayCap``.
    @State private var totalFound: Int
    /// The ticked links, handed to the shared review step.
    @State private var reviewText: String?
    private let seed: Seed?

    init(seed: Seed? = nil) {
        let start = seed ?? Seed()
        self.seed = seed
        _pageText = State(initialValue: start.pageText)
        _isFetching = State(initialValue: start.isFetching)
        _fetchError = State(initialValue: start.fetchError)
        _links = State(initialValue: start.links)
        _selected = State(initialValue: start.selected)
        _categoryFilter = State(initialValue: start.categoryFilter)
        _pastedFromClipboard = State(initialValue: start.pastedFromClipboard)
        _clipboardPrefill = State(initialValue: start.pastedFromClipboard ? start.pageText : nil)
        _totalFound = State(initialValue: start.totalFound)
        _reviewText = State(initialValue: start.reviewText)
    }

    var body: some View {
        Group {
            if let reviewText {
                LinkReviewView(title: L10n.t("Review %d links", selected.count),
                               text: reviewText,
                               truncationNote: LinkReview.truncationNote(shown: links.count, total: totalFound),
                               seed: seed?.reviewItems,
                               back: { self.reviewText = nil }, done: { dismiss() })
            } else {
                pickContent
            }
        }
        .frame(width: reviewText == nil ? 720 : 760)
        .background(Studio.Palette.sheet)
        .onAppear { if seed == nil { prefillFromClipboard() } }
    }

    private var pickContent: some View {
        VStack(spacing: 0) {
            AddFlowHeader(title: L10n.t("Grab links from a page"), symbol: "text.page.badge.magnifyingglass")
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                urlRow
                if pastedFromClipboard {
                    AddPastedNote(clearHelp: L10n.t("Clear pasted link")) {
                        pageText = ""
                        pastedFromClipboard = false
                    }
                }
                status
                if !links.isEmpty {
                    LinkGrabberResults(links: links, selected: $selected, categoryFilter: $categoryFilter)
                    if let note = LinkReview.truncationNote(shown: links.count, total: totalFound) {
                        StudioNote(tone: .neutral, symbol: "info.circle", message: note)
                    }
                }
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xl)
            footer
        }
    }

    private var urlRow: some View {
        HStack(spacing: Studio.Space.s) {
            StudioFocusedField { focus in
                HStack(spacing: Studio.Space.s) {
                    Image(systemName: "globe")
                        .font(StudioFonts.font(.ui, size: 13, weight: 600))
                        .foregroundStyle(Studio.Palette.ink3)
                        .a11yDecorative()
                    TextField(L10n.t("Page URL (https://…)"), text: $pageText)
                        .textFieldStyle(.plain)
                        .studioFont(.monoBody)
                        .focused(focus)
                        .onSubmit(fetch)
                        .accessibilityLabel(L10n.t("Page URL"))
                        .onChange(of: pageText) { _, text in
                            if text != clipboardPrefill { pastedFromClipboard = false }
                        }
                }
            }
            Button(isFetching ? L10n.t("Fetching…") : L10n.t("Fetch"), systemImage: "arrow.down.doc") { fetch() }
                .buttonStyle(.studio(.primary))
                .disabled(isFetching || pageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var status: some View {
        if let fetchError {
            StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill", message: fetchError)
                .accessibilityLabel(L10n.t("Error. %@", fetchError))
        } else if isFetching {
            AddLoadingLine(text: L10n.t("Fetching…"))
        } else if !links.isEmpty {
            AddStatusLine(symbol: "checkmark.circle.fill",
                          text: L10n.t("Found %1$d links on %2$@", totalFound, pageHost),
                          tone: .good)
        } else {
            AddHelpText(L10n.t("Goel° lists every file the page links to, sorted by type. Nothing is downloaded until you review it."))
        }
    }

    private var pageHost: String {
        URL(string: pageText.trimmingCharacters(in: .whitespaces))?.host ?? pageText
    }

    private var footer: some View {
        AddFlowFooter {
            if !links.isEmpty {
                Text(L10n.t("%d selected", selected.count))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
            }
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.studio(.secondary))
            Button(L10n.t("Review Selected…")) { addSelected() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.studio(.primary))
                .disabled(selected.isEmpty)
        }
    }

    private func prefillFromClipboard() {
        guard pageText.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string),
              let url = LinkGrabberPrefill.pageURL(fromClipboard: clip) else { return }
        clipboardPrefill = url
        pageText = url
        pastedFromClipboard = true
    }

    private func fetch() {
        guard let url = URL(string: pageText.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            fetchError = L10n.t("Enter a full http(s) page URL.")
            return
        }
        isFetching = true
        fetchError = nil
        links = []
        totalFound = 0
        selected = []
        categoryFilter = nil
        Task { @MainActor in
            defer { isFetching = false }
            do {
                // Through NetworkGuard: the user's proxy and User-Agent, bounded redirects, no link-local.
                let data = try await NetworkGuard.fetchChecked(
                    url: url, proxy: AppViewModel.proxySpec(from: vm.settings),
                    userAgent: AppViewModel.updateUserAgent(from: vm.settings))
                // Checked before decoding: a page this big is no link list worth scanning.
                guard data.count <= 8_000_000 else {
                    fetchError = L10n.t("That page is too large to scan.")
                    return
                }
                let html = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
                let all = LinkExtractor.extractAll(from: html, baseURL: url)
                totalFound = all.count
                links = Array(all.prefix(LinkExtractor.displayCap))
                if links.isEmpty { fetchError = L10n.t("No downloadable links found on that page.") }
            } catch {
                fetchError = L10n.t("The page couldn’t be loaded: %@", AppViewModel.fetchFailureMessage(error))
            }
        }
    }

    private func addSelected() {
        let ordered = links.filter { selected.contains($0.url) }.map(\.url)
        guard !ordered.isEmpty else { return }
        reviewText = ordered.joined(separator: "\n")
    }
}

/// The type chips, Select All / None and the checklist of found links, two cards per row.
private struct LinkGrabberResults: View {
    let links: [GrabbedLink]
    @Binding var selected: Set<String>
    @Binding var categoryFilter: GrabbedLink.Category?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Studio.Space.s), count: 2)

    private var visibleLinks: [GrabbedLink] {
        guard let categoryFilter else { return links }
        return links.filter { $0.category == categoryFilter }
    }

    private var allVisibleSelected: Bool {
        let visible = visibleLinks
        return !visible.isEmpty && visible.allSatisfy { selected.contains($0.url) }
    }

    private var presentCategories: [GrabbedLink.Category] {
        var seen: [GrabbedLink.Category] = []
        for link in links where !seen.contains(link.category) { seen.append(link.category) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            HStack(alignment: .top, spacing: Studio.Space.s) {
                AddChipFlow {
                    AddFilterChip.all(count: links.count, isOn: categoryFilter == nil) { categoryFilter = nil }
                    ForEach(presentCategories, id: \.self) { category in
                        AddFilterChip.category(category, count: links.filter { $0.category == category }.count,
                                               isOn: categoryFilter == category) { categoryFilter = category }
                    }
                }
                Button(allVisibleSelected ? L10n.t("Select None") : L10n.t("Select All")) {
                    toggleVisibleSelection()
                }
                .buttonStyle(.studio(.ghost, size: .small))
                .fixedSize()
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: Studio.Space.s) {
                    ForEach(visibleLinks, id: \.url) { link in
                        card(link)
                    }
                }
                .padding(Studio.Space.xxs)
            }
            .frame(height: 300)
        }
    }

    private func card(_ link: GrabbedLink) -> some View {
        let isOn = selected.contains(link.url)
        return HStack(spacing: 11) {
            Toggle(isOn: Binding(
                get: { selected.contains(link.url) },
                set: { on in
                    if on { selected.insert(link.url) } else { selected.remove(link.url) }
                }
            )) { EmptyView() }
                .toggleStyle(.studioCheckbox)
                .accessibilityLabel(link.displayName)
            StudioFileArtwork(kind: link.category.artKind, size: .s, isFaded: !isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.displayName)
                    .studioFont(.cardTitle.size(13))
                    .foregroundStyle(isOn ? Studio.Palette.ink : Studio.Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link.url)
                Text([link.category.label, URL(string: link.url)?.host].compactMap { $0 }.joined(separator: " · "))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, 11)
        .studioSurface(.card, radius: Studio.Radius.compactCard, isSelected: false)
    }

    private func toggleVisibleSelection() {
        let visibleURLs = visibleLinks.map(\.url)
        if allVisibleSelected {
            visibleURLs.forEach { selected.remove($0) }
        } else {
            selected.formUnion(visibleURLs)
        }
    }
}
