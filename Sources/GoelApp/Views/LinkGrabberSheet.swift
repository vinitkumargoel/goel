import SwiftUI
import AppKit
import GoelCore

struct LinkGrabberSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageText = ""
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var links: [GrabbedLink] = []
    @State private var selected: Set<String> = []
    @State private var categoryFilter: GrabbedLink.Category?
    @State private var pastedFromClipboard = false
    /// What the prefill put in the field; typing anything else retires the "Pasted" note.
    @State private var clipboardPrefill: String?
    /// Every link the page had; ``links`` keeps the first ``LinkExtractor/displayCap``.
    @State private var totalFound = 0
    /// The ticked links, handed to the shared review step.
    @State private var reviewText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(systemImage: "text.page.badge.magnifyingglass",
                        title: reviewText == nil ? L10n.t("Grab links from a page")
                                                 : L10n.t("Review %d links", selected.count))
            Divider()
            if let reviewText {
                LinkReviewView(text: reviewText,
                               truncationNote: LinkReview.truncationNote(shown: links.count, total: totalFound),
                               back: { self.reviewText = nil }, done: { dismiss() })
            } else {
                pickContent
            }
        }
        .frame(width: reviewText == nil ? 620 : 720)
        .onAppear(perform: prefillFromClipboard)
    }

    private var pickContent: some View {
        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField(L10n.t("Page URL (https://…)"), text: $pageText)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(size: Theme.TextSize.body, design: .monospaced)
                        .onSubmit(fetch)
                        .accessibilityLabel(L10n.t("Page URL"))
                        .onChange(of: pageText) { _, text in
                            if text != clipboardPrefill { pastedFromClipboard = false }
                        }
                    Button(isFetching ? L10n.t("Fetching…") : L10n.t("Fetch")) { fetch() }
                        .disabled(isFetching || pageText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if pastedFromClipboard {
                    PastedFromClipboardNote(clearHelp: L10n.t("Clear pasted link")) {
                        pageText = ""
                        pastedFromClipboard = false
                    }
                }
                if let fetchError {
                    Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(Theme.orange)
                        .accessibilityLabel(L10n.t("Error. %@", fetchError))
                }
                if !links.isEmpty {
                    filterChips
                    linkList
                    HStack {
                        Button(allVisibleSelected ? L10n.t("Select None") : L10n.t("Select All")) {
                            toggleVisibleSelection()
                        }
                        Spacer()
                        Text(L10n.t("%d selected", selected.count))
                            .scaledFont(size: Theme.TextSize.meta)
                            .foregroundStyle(.secondary)
                    }
                    if let note = LinkReview.truncationNote(shown: links.count, total: totalFound) {
                        Label(note, systemImage: "info.circle")
                            .scaledFont(size: Theme.TextSize.meta)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Review Selected…")) { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
            .padding(14)
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

    private var visibleLinks: [GrabbedLink] {
        guard let categoryFilter else { return links }
        return links.filter { $0.category == categoryFilter }
    }

    private var allVisibleSelected: Bool {
        let visible = visibleLinks
        return !visible.isEmpty && visible.allSatisfy { selected.contains($0.url) }
    }

    private func toggleVisibleSelection() {
        let visibleURLs = visibleLinks.map(\.url)
        if allVisibleSelected {
            visibleURLs.forEach { selected.remove($0) }
        } else {
            selected.formUnion(visibleURLs)
        }
    }

    private var presentCategories: [GrabbedLink.Category] {
        var seen: [GrabbedLink.Category] = []
        for link in links where !seen.contains(link.category) { seen.append(link.category) }
        return seen
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            chip(L10n.t("All (%d)", links.count), active: categoryFilter == nil) { categoryFilter = nil }
            ForEach(presentCategories, id: \.self) { category in
                let count = links.filter { $0.category == category }.count
                chip(L10n.t("%1$@ (%2$@)", category.label, String(count)), active: categoryFilter == category) {
                    categoryFilter = category
                }
            }
            Spacer()
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: Theme.TextSize.meta, weight: active ? .semibold : .regular)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                            in: Capsule())
                .foregroundStyle(active ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var linkList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleLinks, id: \.url) { link in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(link.url) },
                            set: { on in
                                if on { selected.insert(link.url) } else { selected.remove(link.url) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(link.displayName)
                        Text(link.displayName)
                            .scaledFont(size: Theme.TextSize.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(link.url)
                        Spacer(minLength: 8)
                        Text(link.category.label)
                            .scaledFont(size: Theme.TextSize.micro)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(height: 240)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.hairline))
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

struct GrabbedLink: Hashable {
    enum Category: Hashable {
        case archive, video, audio, image, software, document, other
        var label: String {
            switch self {
            case .archive: return L10n.t("Archives")
            case .video: return L10n.t("Video")
            case .audio: return L10n.t("Audio")
            case .image: return L10n.t("Images")
            case .software: return L10n.t("Software")
            case .document: return L10n.t("Documents")
            case .other: return L10n.t("Other")
            }
        }
    }

    var url: String
    var category: Category
    var displayName: String {
        let last = URL(string: url)?.lastPathComponent ?? ""
        return last.isEmpty ? url : last
    }
}

enum LinkExtractor {

    private static let extensionCategories: [(Set<String>, GrabbedLink.Category)] = [
        (["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz"], .archive),
        (["mp4", "mkv", "webm", "avi", "mov", "m4v", "ts", "m3u8"], .video),
        (["mp3", "m4a", "flac", "wav", "ogg", "aac", "opus"], .audio),
        (["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp"], .image),
        (["dmg", "pkg", "exe", "msi", "deb", "rpm", "appimage", "apk", "xip"], .software),
        (["pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv"], .document),
        (["iso", "img", "bin", "torrent"], .other),
    ]

    /// The grabber shows at most this many; ``extractAll(from:baseURL:)`` says how many there were.
    static let displayCap = 500

    static func extract(from html: String, baseURL: URL) -> [GrabbedLink] {
        Array(extractAll(from: html, baseURL: baseURL).prefix(displayCap))
    }

    static func extractAll(from html: String, baseURL: URL) -> [GrabbedLink] {
        var seen = Set<String>()
        var results: [GrabbedLink] = []
        let pattern = #"(?:href|src)\s*=\s*["']([^"'<>\s]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else { return }
            guard let category = category(for: resolved) else { return }
            let absolute = resolved.absoluteString
            guard seen.insert(absolute).inserted else { return }
            results.append(GrabbedLink(url: absolute, category: category))
        }
        return results
    }

    static func category(for url: URL) -> GrabbedLink.Category? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        for (extensions, category) in extensionCategories where extensions.contains(ext) {
            return category
        }
        return nil
    }
}

/// The first web link on the clipboard, for the grabber's page field; nil when there is none.
enum LinkGrabberPrefill {
    /// A pasted essay isn't worth scanning token by token.
    private static let maxScanned = 20_000

    static func pageURL(fromClipboard text: String) -> String? {
        let tokens = text.prefix(maxScanned).split(whereSeparator: { $0.isWhitespace })
        for token in tokens {
            let candidate = String(token)
            guard let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { continue }
            return candidate
        }
        return nil
    }
}
