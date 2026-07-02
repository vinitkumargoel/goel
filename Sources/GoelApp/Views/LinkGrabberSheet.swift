import SwiftUI
import GoelCore

/// The page link grabber: fetch a web page, list every downloadable-looking
/// link it references (grouped by type), pick some, queue them.
struct LinkGrabberSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageText = ""
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var links: [GrabbedLink] = []
    @State private var selected: Set<String> = []
    @State private var categoryFilter: GrabbedLink.Category?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "text.page.badge.magnifyingglass")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                Text("Grab links from a page")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(18)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Page URL (https://…)", text: $pageText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(fetch)
                    Button(isFetching ? "Fetching…" : "Fetch") { fetch() }
                        .disabled(isFetching || pageText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let fetchError {
                    Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                }
                if !links.isEmpty {
                    filterChips
                    linkList
                    HStack {
                        Button(selected.count == visibleLinks.count ? "Select None" : "Select All") {
                            if selected.count == visibleLinks.count {
                                selected.removeAll()
                            } else {
                                selected = Set(visibleLinks.map(\.url))
                            }
                        }
                        Spacer()
                        Text("\(selected.count) selected")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 620)
    }

    private var visibleLinks: [GrabbedLink] {
        guard let categoryFilter else { return links }
        return links.filter { $0.category == categoryFilter }
    }

    private var presentCategories: [GrabbedLink.Category] {
        var seen: [GrabbedLink.Category] = []
        for link in links where !seen.contains(link.category) { seen.append(link.category) }
        return seen
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            chip("All (\(links.count))", active: categoryFilter == nil) { categoryFilter = nil }
            ForEach(presentCategories, id: \.self) { category in
                let count = links.filter { $0.category == category }.count
                chip("\(category.label) (\(count))", active: categoryFilter == category) {
                    categoryFilter = category
                }
            }
            Spacer()
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                            in: Capsule())
                .foregroundStyle(active ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
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
                        Text(link.displayName)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(link.url)
                        Spacer(minLength: 8)
                        Text(link.category.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(height: 240)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }

    private func fetch() {
        guard let url = URL(string: pageText.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            fetchError = "Enter a full http(s) page URL."
            return
        }
        isFetching = true
        fetchError = nil
        links = []
        selected = []
        categoryFilter = nil
        Task { @MainActor in
            defer { isFetching = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    fetchError = "The page couldn’t be loaded."
                    return
                }
                guard data.count <= 8_000_000 else {
                    fetchError = "That page is too large to scan."
                    return
                }
                let html = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
                links = LinkExtractor.extract(from: html, baseURL: url)
                if links.isEmpty { fetchError = "No downloadable links found on that page." }
            } catch {
                fetchError = "The page couldn’t be loaded."
            }
        }
    }

    private func addSelected() {
        let ordered = links.filter { selected.contains($0.url) }.map(\.url)
        guard !ordered.isEmpty else { return }
        vm.add(rawLines: ordered.joined(separator: "\n"), saveDirectory: nil, priority: .normal)
        dismiss()
    }
}

// MARK: - Extraction

/// One link found on a page.
struct GrabbedLink: Hashable {
    enum Category: Hashable {
        case archive, video, audio, image, software, document, other
        var label: String {
            switch self {
            case .archive: return "Archives"
            case .video: return "Video"
            case .audio: return "Audio"
            case .image: return "Images"
            case .software: return "Software"
            case .document: return "Documents"
            case .other: return "Other"
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

    /// Pull every href/src target out of the HTML, absolutize against the
    /// page URL, and keep the ones that look like downloadable payloads.
    static func extract(from html: String, baseURL: URL) -> [GrabbedLink] {
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
        return Array(results.prefix(500))
    }

    /// The category for a URL with a downloadable-looking extension, else nil.
    private static func category(for url: URL) -> GrabbedLink.Category? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        for (extensions, category) in extensionCategories where extensions.contains(ext) {
            return category
        }
        return nil
    }
}
