import SwiftUI
import GoelCore

/// Lets the user pick WHICH rendition of a video-site page to download, instead
/// of accepting whatever the resolver picks.
///
/// The existing `hlsMaxHeight` preference only caps HLS renditions and only in
/// coarse steps; it cannot express "the 1080p VP9 one" or "just the audio". This
/// view shows the same table `yt-dlp -F` prints, so the choice a user could make
/// on the command line is available in the app.
///
/// Deliberately a **standalone child view**: it owns no app state, takes a URL
/// in and hands a `MediaFormat?` back through `onSelect` (nil meaning "let
/// yt-dlp choose"). That keeps it previewable in isolation and keeps the parent
/// sheet free of the loading/error states this view manages itself.
struct MediaFormatPicker: View {

    /// The page whose renditions are being listed.
    let pageURL: URL

    /// Called whenever the selection changes. `nil` means "Best available" — the
    /// caller should then omit `-f` entirely rather than guess a format id.
    var onSelect: (MediaFormat?) -> Void

    /// Pre-supplied rows. When non-nil no yt-dlp process is started at all, which
    /// is what makes the SwiftUI preview below work offline and lets a caller
    /// that already listed formats reuse the result.
    var preloadedFormats: [MediaFormat]?

    init(pageURL: URL,
         preloadedFormats: [MediaFormat]? = nil,
         onSelect: @escaping (MediaFormat?) -> Void) {
        self.pageURL = pageURL
        self.preloadedFormats = preloadedFormats
        self.onSelect = onSelect
    }

    /// What the body is currently showing.
    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var formats: [MediaFormat] = []
    /// The chosen format id; nil is the "Best available" row.
    @State private var selectedID: String?
    /// Reveals video-only / audio-only tracks, which need a merge step.
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
                    Toggle("Show video-only and audio-only tracks", isOn: $showSeparateTracks)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: pageURL) { await load() }
        .onDisappear { loadTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Quality", systemImage: "square.stack.3d.up")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if phase == .loaded {
                Text("\(visibleFormats.count) option\(visibleFormats.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if case .failed = phase {
                Button("Retry") { Task { await load(force: true) } }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Asking yt-dlp what’s available…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func failureRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: List

    private var formatList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                row(id: nil,
                    quality: "Best available",
                    detail: "Let yt-dlp choose — always a single ready-to-play file.",
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
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
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
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(quality)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Theme.accent.opacity(0.10) : .clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: Row content

    /// `mp4 · avc1 + aac · 1080p` — codec/container facts in the order a person
    /// scans them, with empty pieces dropped rather than shown as blanks.
    private func detailText(for format: MediaFormat) -> String {
        var pieces: [String] = [format.ext]
        let codecs = [format.vcodec, format.acodec]
            .compactMap { $0 }
            .map { $0.split(separator: ".").first.map(String.init) ?? $0 }
        if !codecs.isEmpty { pieces.append(codecs.joined(separator: " + ")) }
        if format.isVideoOnly { pieces.append("no sound — merged with an audio track") }
        if format.isAudioOnly { pieces.append("audio only") }
        if !format.note.isEmpty { pieces.append(format.note) }
        return pieces.joined(separator: " · ")
    }

    private func sizeText(for format: MediaFormat) -> String? {
        guard let bytes = format.fileSizeBytes else { return nil }
        return (format.isApproximateSize ? "~" : "") + bytes.byteString
    }

    // MARK: Ordering and filtering

    /// Single-file renditions, highest quality first. These are the safe default:
    /// picking a video-only track without a merge yields a silent file.
    private var selfContainedFormats: [MediaFormat] {
        formats.filter(\.isSelfContained).sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }

    /// Video-only and audio-only tracks, which yt-dlp must merge with ffmpeg.
    private var separateTrackFormats: [MediaFormat] {
        formats.filter { !$0.isSelfContained }.sorted {
            // Video tracks (tallest first) above audio tracks.
            if $0.hasVideo != $1.hasVideo { return $0.hasVideo }
            return ($0.height ?? 0) > ($1.height ?? 0)
        }
    }

    private var visibleFormats: [MediaFormat] {
        showSeparateTracks ? selfContainedFormats + separateTrackFormats : selfContainedFormats
    }

    // MARK: Loading

    /// Ask yt-dlp for the format table. `force` re-runs after a failure; the
    /// normal path short-circuits on `preloadedFormats` and skips the process.
    private func load(force: Bool = false) async {
        if let preloadedFormats {
            formats = preloadedFormats
            phase = preloadedFormats.isEmpty
                ? .failed("No formats were supplied.")
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
                // Every listed format needing a merge is worth surfacing up front
                // rather than hiding behind a checkbox the user never ticks.
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

// MARK: - Playlist checklist

/// Lists every item behind a playlist/channel URL so the user ticks the ones
/// they actually want, instead of the app queueing all 400 or none.
///
/// Lives beside ``MediaFormatPicker`` because it is the same shape of problem:
/// one pasted URL, a list yt-dlp produced, a choice the user makes before
/// anything is queued. Parsing is entirely in `GoelCore`'s ``PlaylistExpander``;
/// this view only runs the tool and renders the result.
struct PlaylistChecklistView: View {

    let playlistURL: URL

    /// Called with the ticked items, in playlist order, when the user confirms.
    var onConfirm: ([PlaylistItem]) -> Void

    /// Pre-supplied expansion — skips the yt-dlp run (preview / reuse).
    var preloadedExpansion: PlaylistExpansion?

    init(playlistURL: URL,
         preloadedExpansion: PlaylistExpansion? = nil,
         onConfirm: @escaping ([PlaylistItem]) -> Void) {
        self.playlistURL = playlistURL
        self.preloadedExpansion = preloadedExpansion
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
        VStack(alignment: .leading, spacing: 10) {
            header
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Listing what’s in this playlist…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
            Label(phase == .loaded && !expansion.title.isEmpty ? expansion.title : "Playlist",
                  systemImage: "list.bullet.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if phase == .loaded {
                Text("\(expansion.items.count) item\(expansion.items.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
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
                        Text("\(item.index).")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(item.title)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.url)
                        Spacer(minLength: 8)
                        if let duration = item.durationText {
                            Text(duration)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A truncated listing must say so — showing 1 000 of a 4 000-video
            // channel and calling it "everything" is a lie the user only finds
            // out about later.
            if expansion.truncated {
                Text("Only the first \(PlaylistExpander.cap) items are shown.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.orange)
            }
            HStack {
                Button(allSelected ? "Select None" : "Select All") {
                    selected = allSelected ? [] : Set(expansion.items.map(\.id))
                }
                Spacer()
                Text("\(selected.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Add Selected") {
                    onConfirm(expansion.items.filter { selected.contains($0.id) })
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
    }

    private var allSelected: Bool {
        !expansion.items.isEmpty && selected.count == expansion.items.count
    }

    private func load() async {
        if let preloadedExpansion {
            expansion = preloadedExpansion
            selected = Set(preloadedExpansion.items.map(\.id))
            phase = preloadedExpansion.items.isEmpty
                ? .failed("That playlist doesn’t list any downloadable items.")
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
                // Everything ticked by default: the user pasted a playlist, so
                // "all of it" is the likely intent, and unticking is easier than
                // hunting for the ones you want.
                selected = Set(result.items.map(\.id))
                phase = .loaded
            case .notAPlaylist:
                phase = .failed("That link is a single video, not a playlist.")
            case .failed(let message):
                phase = .failed(message)
            }
        }
        loadTask = task
        await task.value
    }
}

#if DEBUG
/// Fixture-backed previews — no network, no yt-dlp, no app state.
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
