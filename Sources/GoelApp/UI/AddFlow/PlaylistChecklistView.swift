import SwiftUI
import GoelCore

/// A playlist link as a checklist: every item ticked, one preset for all of them. Fills the Add
/// sheet's second step, with its own header and footer so a slow or failed listing never traps
/// the user.
struct PlaylistChecklistView: View {

    /// The ways out of the checklist.
    struct SheetActions {
        var back: () -> Void
        var singleVideo: () -> Void
        var cancel: () -> Void
    }

    let playlistURL: URL
    let sheetActions: SheetActions
    /// Settings › Max video quality, for the Best preset's label and selector.
    var maxHeight: Int = 0
    /// Snapshot seam: a listing to show instead of asking yt-dlp. Nil in the app.
    var seed: AddListingSeed<PlaylistExpansion>?
    /// The ticked items and the preset every one of them is downloaded as.
    var onConfirm: ([PlaylistItem], MediaPreset?) -> Void

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var expansion = PlaylistExpansion(title: "", items: [])
    @State private var selected: Set<String> = []
    @State private var loadTask: Task<Void, Never>?
    @State private var preset: MediaPreset? = .best

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xl)
            footer
        }
        .task(id: playlistURL) { await load() }
        .onDisappear { loadTask?.cancel() }
    }

    private var header: some View {
        let count = expansion.items.count
        let eyebrow = phase == .loaded
            ? L10n.t("Step 2 of 2") + " · " + (count == 1 ? L10n.t("%d item", count) : L10n.t("%d items", count))
            : L10n.t("Step 2 of 2")
        return AddFlowHeader(title: phase == .loaded && !expansion.title.isEmpty ? expansion.title : L10n.t("Playlist"),
                             eyebrow: eyebrow, symbol: "list.bullet.rectangle")
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            AddLoadingLine(text: L10n.t("Listing what’s in this playlist…"),
                           accessibilityLabel: L10n.t("Listing what’s in this playlist"))
                .padding(.vertical, Studio.Space.l)
        case .failed(let message):
            StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill", message: message)
                .accessibilityLabel(L10n.t("Couldn’t list the playlist. %@", message))
        case .loaded:
            selectionBar
            itemList
            if expansion.truncated {
                AddStatusLine(symbol: "info.circle",
                              text: L10n.t("Only the first %d items are shown.", PlaylistExpander.cap),
                              tone: .warn)
            }
            AddFieldLabel(L10n.t("Download as"))
            MediaPresetGrid(maxHeight: maxHeight, selection: $preset)
        }
    }

    private var selectionBar: some View {
        HStack {
            Button(allSelected ? L10n.t("Select None") : L10n.t("Select All")) {
                selected = allSelected ? [] : Set(expansion.items.map(\.id))
            }
            .buttonStyle(.studio(.ghost, size: .small))
            Spacer()
            Text(L10n.t("%d selected", selected.count))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .accessibilityLabel(L10n.t("%1$@ of %2$@ items selected", String(selected.count),
                                           String(expansion.items.count)))
        }
    }

    private var itemList: some View {
        AddListWell(height: 250) {
            LazyVStack(spacing: Studio.Space.hair) {
                ForEach(expansion.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: PlaylistItem) -> some View {
        let isOn = selected.contains(item.id)
        return HStack(spacing: Studio.Space.sm) {
            Toggle(isOn: Binding(
                get: { selected.contains(item.id) },
                set: { on in
                    if on { selected.insert(item.id) } else { selected.remove(item.id) }
                }
            )) { EmptyView() }
                .toggleStyle(.studioCheckbox)
                .accessibilityLabel(L10n.t("%1$@. %2$@", String(item.index), item.title))
            Text(verbatim: "\(item.index).")
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
                .frame(minWidth: 22, alignment: .trailing)
                .a11yDecorative()
            StudioFileArtwork(kind: .video, size: .s, isFaded: !isOn)
            Text(item.title)
                .studioFont(.body)
                .foregroundStyle(isOn ? Studio.Palette.ink : Studio.Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url)
                .a11yDecorative()
            Spacer(minLength: Studio.Space.s)
            if let duration = item.durationText {
                Text(duration)
                    .studioFont(.mono)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityLabel(L10n.t("Duration %@", duration))
            }
        }
        .padding(.horizontal, Studio.Space.sm)
        .padding(.vertical, Studio.Space.xs)
    }

    private var footer: some View {
        AddFlowFooter {
            Button(L10n.t("Back"), systemImage: "chevron.left") {
                loadTask?.cancel()
                sheetActions.back()
            }
            .buttonStyle(.studio(.ghost))
            Button(L10n.t("Download this video only")) {
                loadTask?.cancel()
                sheetActions.singleVideo()
            }
            .buttonStyle(.studio(.ghost))
            .help(L10n.t("Skip the playlist and download just the video this link points to."))
            Spacer()
            Button(L10n.t("Cancel")) {
                loadTask?.cancel()
                sheetActions.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.studio(.secondary))
            Button(L10n.t("Add Selected")) {
                onConfirm(expansion.items.filter { selected.contains($0.id) }, preset)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.studio(.primary))
            .disabled(phase != .loaded || selected.isEmpty)
        }
    }

    private var allSelected: Bool {
        !expansion.items.isEmpty && selected.count == expansion.items.count
    }

    private func apply(_ result: PlaylistExpansion) {
        expansion = result
        selected = Set(result.items.map(\.id))
        phase = .loaded
    }

    private func load() async {
        if let seed {
            switch seed {
            case .loading: phase = .loading
            case .loaded(let result) where result.items.isEmpty:
                phase = .failed(L10n.t("That playlist doesn’t list any downloadable items."))
            case .loaded(let result):
                apply(result)
            case .failed(let message): phase = .failed(message)
            }
            return
        }
        loadTask?.cancel()
        phase = .loading
        let task = Task { @MainActor in
            let outcome = await YtDlpResolver.expandPlaylist(playlistURL)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .expanded(let result):
                apply(result)
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
