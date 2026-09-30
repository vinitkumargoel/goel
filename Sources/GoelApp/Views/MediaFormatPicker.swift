import SwiftUI
import GoelCore

struct MediaFormatPicker: View {

    let pageURL: URL

    /// `nil` means "Best available" — the caller must then omit `-f`, not guess a format id.
    var onSelect: (MediaFormat?) -> Void

    var preloadedFormats: [MediaFormat]?

    init(pageURL: URL,
         preloadedFormats: [MediaFormat]? = nil,
         onSelect: @escaping (MediaFormat?) -> Void) {
        self.pageURL = pageURL
        self.preloadedFormats = preloadedFormats
        self.onSelect = onSelect
    }

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var formats: [MediaFormat] = []
    @State private var selectedID: String?
    @State private var showSeparateTracks = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch phase {
            case .loading:
                loadingRow
            case .failed(let message):
                failureRow(message)
            case .loaded:
                formatList
                if !separateTrackFormats.isEmpty {
                    Toggle(L10n.t("Show video-only and audio-only tracks"), isOn: $showSeparateTracks)
                        .toggleStyle(.checkbox)
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: pageURL) { await load() }
        .onDisappear { loadTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(L10n.t("Quality"), systemImage: "square.stack.3d.up")
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if phase == .loaded {
                Text(visibleFormats.count == 1
                     ? L10n.t("%d option", visibleFormats.count)
                     : L10n.t("%d options", visibleFormats.count))
                    .scaledFont(size: Theme.TextSize.micro)
                    .foregroundStyle(.tertiary)
            }
            if case .failed = phase {
                Button(L10n.t("Retry")) { Task { await load(force: true) } }
                    .buttonStyle(.link)
                    .scaledFont(size: Theme.TextSize.meta)
                    .accessibilityLabel(L10n.t("Retry loading quality options"))
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
                .a11yDecorative()
            Text(L10n.t("Asking yt-dlp what’s available…"))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .a11yGroup(label: L10n.t("Asking yt-dlp what’s available"))
    }

    private func failureRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .scaledFont(size: Theme.TextSize.meta)
            .foregroundStyle(Theme.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(L10n.t("Couldn’t load quality options. %@", message))
    }

    private var formatList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                row(id: nil,
                    quality: L10n.t("Best available"),
                    detail: L10n.t("Let yt-dlp choose — always a single ready-to-play file."),
                    trailing: nil)
                ForEach(visibleFormats) { format in
                    row(id: format.id,
                        quality: format.qualityLabel,
                        detail: detailText(for: format),
                        trailing: sizeText(for: format))
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.hairline))
    }

    private func row(id: String?, quality: String, detail: String, trailing: String?) -> some View {
        let isSelected = id == selectedID
        return Button {
            selectedID = id
            onSelect(id.flatMap { chosen in formats.first { $0.id == chosen } })
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.5))
                    .scaledFont(size: Theme.TextSize.body)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quality)
                        .scaledFont(size: Theme.TextSize.meta, weight: isSelected ? .semibold : .regular)
                    Text(detail)
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .scaledFont(size: Theme.TextSize.caption, design: .monospaced)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Theme.accent.opacity(0.10) : .clear)
        }
        .buttonStyle(.plain)
        .a11yGroup(label: quality, value: A11y.sentence(detail, trailing))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func detailText(for format: MediaFormat) -> String {
        var pieces: [String] = [format.ext]
        let codecs = [format.vcodec, format.acodec]
            .compactMap { $0 }
            .map { $0.split(separator: ".").first.map(String.init) ?? $0 }
        if !codecs.isEmpty { pieces.append(codecs.joined(separator: " + ")) }
        if format.isVideoOnly { pieces.append(L10n.t("no sound — merged with an audio track")) }
        if format.isAudioOnly { pieces.append(L10n.t("audio only")) }
        if !format.note.isEmpty { pieces.append(format.note) }
        return pieces.joined(separator: " · ")
    }

    private func sizeText(for format: MediaFormat) -> String? {
        guard let bytes = format.fileSizeBytes else { return nil }
        return (format.isApproximateSize ? "~" : "") + bytes.byteString
    }

    /// The safe default: a video-only track picked without a merge step yields a silent file.
    private var selfContainedFormats: [MediaFormat] {
        formats.filter(\.isSelfContained).sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }

    private var separateTrackFormats: [MediaFormat] {
        formats.filter { !$0.isSelfContained }.sorted {
            if $0.hasVideo != $1.hasVideo { return $0.hasVideo }
            return ($0.height ?? 0) > ($1.height ?? 0)
        }
    }

    private var visibleFormats: [MediaFormat] {
        showSeparateTracks ? selfContainedFormats + separateTrackFormats : selfContainedFormats
    }

    private func load(force: Bool = false) async {
        if let preloadedFormats {
            formats = preloadedFormats
            phase = preloadedFormats.isEmpty
                ? .failed(L10n.t("No formats were supplied."))
                : .loaded
            return
        }
        if !force, phase == .loaded, !formats.isEmpty { return }
        loadTask?.cancel()
        phase = .loading
        let task = Task { @MainActor in
            let outcome = await YtDlpResolver.listFormats(pageURL)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .formats(let listed):
                formats = listed
                if listed.allSatisfy({ !$0.isSelfContained }) { showSeparateTracks = true }
                phase = .loaded
            case .failed(let message):
                formats = []
                phase = .failed(message)
            }
        }
        loadTask = task
        await task.value
    }
}

struct PlaylistChecklistView: View {

    /// The ways out of the checklist when it fills a sheet step. With these the view draws the
    /// sheet's standard footer in every state, so a slow or failed listing never traps the user.
    struct SheetActions {
        var back: () -> Void
        var singleVideo: () -> Void
        var cancel: () -> Void
    }

    let playlistURL: URL

    var onConfirm: ([PlaylistItem]) -> Void

    var preloadedExpansion: PlaylistExpansion?

    var sheetActions: SheetActions?

    init(playlistURL: URL,
         preloadedExpansion: PlaylistExpansion? = nil,
         sheetActions: SheetActions? = nil,
         onConfirm: @escaping ([PlaylistItem]) -> Void) {
        self.playlistURL = playlistURL
        self.preloadedExpansion = preloadedExpansion
        self.sheetActions = sheetActions
        self.onConfirm = onConfirm
    }

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var expansion = PlaylistExpansion(title: "", items: [])
    @State private var selected: Set<String> = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        if let sheetActions {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                Divider()
                sheetFooter(sheetActions)
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                        .a11yDecorative()
                    Text(L10n.t("Listing what’s in this playlist…"))
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(.secondary)
                }
                .a11yGroup(label: L10n.t("Listing what’s in this playlist"))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.t("Couldn’t list the playlist. %@", message))
            case .loaded:
                itemList
                footer
            }
        }
        .task(id: playlistURL) { await load() }
        .onDisappear { loadTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(phase == .loaded && !expansion.title.isEmpty ? expansion.title : L10n.t("Playlist"),
                  systemImage: "list.bullet.rectangle")
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if phase == .loaded {
                Text(expansion.items.count == 1
                     ? L10n.t("%d item", expansion.items.count)
                     : L10n.t("%d items", expansion.items.count))
                    .scaledFont(size: Theme.TextSize.micro)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(expansion.items) { item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selected.contains(item.id) },
                            set: { on in
                                if on { selected.insert(item.id) } else { selected.remove(item.id) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(L10n.t("%1$@. %2$@", String(item.index), item.title))
                        Text("\(item.index).")
                            .scaledFont(size: Theme.TextSize.micro, design: .monospaced)
                            .foregroundStyle(.tertiary)
                            .a11yDecorative()
                        Text(item.title)
                            .scaledFont(size: Theme.TextSize.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.url)
                            .a11yDecorative()
                        Spacer(minLength: 8)
                        if let duration = item.durationText {
                            Text(duration)
                                .scaledFont(size: Theme.TextSize.micro, design: .monospaced)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel(L10n.t("Duration %@", duration))
                        }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expansion.truncated {
                Text(L10n.t("Only the first %d items are shown.", PlaylistExpander.cap))
                    .scaledFont(size: Theme.TextSize.micro)
                    .foregroundStyle(Theme.orange)
            }
            HStack {
                Button(allSelected ? L10n.t("Select None") : L10n.t("Select All")) {
                    selected = allSelected ? [] : Set(expansion.items.map(\.id))
                }
                Spacer()
                Text(L10n.t("%d selected", selected.count))
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.t("%1$@ of %2$@ items selected", String(selected.count), String(expansion.items.count)))
                if sheetActions == nil {
                    addSelectedButton
                }
            }
        }
    }

    private var addSelectedButton: some View {
        Button(L10n.t("Add Selected")) {
            onConfirm(expansion.items.filter { selected.contains($0.id) })
        }
        .buttonStyle(.borderedProminent)
        .disabled(phase != .loaded || selected.isEmpty)
    }

    private func sheetFooter(_ actions: SheetActions) -> some View {
        HStack {
            Button(L10n.t("Back")) {
                loadTask?.cancel()
                actions.back()
            }
            Button(L10n.t("Download this video only")) {
                loadTask?.cancel()
                actions.singleVideo()
            }
            .help(L10n.t("Skip the playlist and download just the video this link points to."))
            Spacer()
            Button(L10n.t("Cancel")) {
                loadTask?.cancel()
                actions.cancel()
            }
            .keyboardShortcut(.cancelAction)
            addSelectedButton
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var allSelected: Bool {
        !expansion.items.isEmpty && selected.count == expansion.items.count
    }

    private func load() async {
        if let preloadedExpansion {
            expansion = preloadedExpansion
            selected = Set(preloadedExpansion.items.map(\.id))
            phase = preloadedExpansion.items.isEmpty
                ? .failed(L10n.t("That playlist doesn’t list any downloadable items."))
                : .loaded
            return
        }
        loadTask?.cancel()
        phase = .loading
        let task = Task { @MainActor in
            let outcome = await YtDlpResolver.expandPlaylist(playlistURL)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .expanded(let result):
                expansion = result
                selected = Set(result.items.map(\.id))
                phase = .loaded
            case .notAPlaylist:
                phase = .failed(L10n.t("That link is a single video, not a playlist."))
            case .failed(let message):
                phase = .failed(message)
            }
        }
        loadTask = task
        await task.value
    }
}

#if DEBUG
private let previewFormatTable = """
[info] Available formats for dQw4w9WgXcQ:
ID  EXT   RESOLUTION FPS CH |   FILESIZE   TBR PROTO | VCODEC        VBR ACODEC      ABR ASR MORE INFO
--- ----- ---------- --- -- - --------- ----- ------ - ------------ ---- ---------- ---- --- ---------
139 m4a   audio only       2 |   1.29MiB   49k https | audio only        mp4a.40.5    49k 22k low, m4a_dash
140 m4a   audio only       2 |   3.43MiB  130k https | audio only        mp4a.40.2   130k 44k medium
18  mp4   640x360     30  2 |   9.78MiB  372k https | avc1.42001E  372k mp4a.40.2      0k 44k 360p
137 mp4   1920x1080   30    |  50.85MiB 1955k https | avc1.640028 1955k video only          1080p
248 webm  1920x1080   30    |  44.11MiB 1696k https | vp9         1696k video only          1080p
"""

#Preview("Format picker") {
    MediaFormatPicker(pageURL: URL(string: "https://example.com/watch?v=x")!,
                      preloadedFormats: MediaFormatTable.parse(previewFormatTable)) { _ in }
        .padding(16)
        .frame(width: 460)
}

#Preview("Playlist checklist") {
    PlaylistChecklistView(
        playlistURL: URL(string: "https://example.com/playlist?list=PL1")!,
        preloadedExpansion: PlaylistExpansion(
            title: "Build Logs",
            items: (1...8).map {
                PlaylistItem(id: "id\($0)", title: "Episode \($0) — a fairly long video title",
                             url: "https://example.com/watch?v=id\($0)",
                             durationSeconds: 200 * $0, index: $0)
            })) { _ in }
        .padding(16)
        .frame(width: 460)
}
#endif
