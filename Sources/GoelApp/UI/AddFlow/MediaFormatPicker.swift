import SwiftUI
import GoelCore

/// The full quality list yt-dlp reports for a page: "Best available" first, then every
/// self-contained format, and on request the video-only and audio-only tracks.
struct MediaFormatPicker: View {

    let pageURL: URL

    /// `nil` means "Best available" — the caller must then omit `-f`, not guess a format id.
    var onSelect: (MediaFormat?) -> Void

    var preloadedFormats: [MediaFormat]?

    /// Snapshot seam: a listing state to show instead of asking yt-dlp. Nil in the app.
    var seed: AddListingSeed<[MediaFormat]>?

    /// Whether yt-dlp listed formats for the page: with the default "Best available" row the caller
    /// sees no selection, yet must still resolve through yt-dlp instead of saving the page's HTML.
    var onListed: (Bool) -> Void

    init(pageURL: URL,
         preloadedFormats: [MediaFormat]? = nil,
         seed: AddListingSeed<[MediaFormat]>? = nil,
         showsSeparateTracks: Bool = false,
         onListed: @escaping (Bool) -> Void = { _ in },
         onSelect: @escaping (MediaFormat?) -> Void) {
        self.pageURL = pageURL
        self.preloadedFormats = preloadedFormats
        self.seed = seed
        self.onListed = onListed
        self.onSelect = onSelect
        _showSeparateTracks = State(initialValue: showsSeparateTracks)
    }

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var formats: [MediaFormat] = []
    @State private var selectedID: String?
    @State private var showSeparateTracks: Bool
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            header
            switch phase {
            case .loading:
                AddLoadingLine(text: L10n.t("Asking yt-dlp what’s available…"),
                               accessibilityLabel: L10n.t("Asking yt-dlp what’s available"))
            case .failed(let message):
                AddStatusLine(symbol: "exclamationmark.triangle.fill", text: message, tone: .warn, tintsText: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.t("Couldn’t load quality options. %@", message))
            case .loaded:
                formatList
                if !separateTrackFormats.isEmpty {
                    HStack {
                        Text(L10n.t("Show video-only and audio-only tracks"))
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink2)
                        Spacer()
                        Toggle(isOn: $showSeparateTracks) { EmptyView() }
                            .toggleStyle(.studioSwitch)
                            .accessibilityLabel(L10n.t("Show video-only and audio-only tracks"))
                    }
                    .padding(.horizontal, Studio.Space.sm)
                }
            }
        }
        .task(id: pageURL) { await load() }
        .onChange(of: phase) { _, newPhase in onListed(newPhase == .loaded && !formats.isEmpty) }
        .onDisappear {
            loadTask?.cancel()
            onListed(false)
        }
    }

    private var header: some View {
        HStack(spacing: Studio.Space.s) {
            Image(systemName: "square.stack.3d.up")
                .font(StudioFonts.font(.ui, size: 12, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .a11yDecorative()
            AddFieldLabel(L10n.t("Quality"))
            Spacer()
            if phase == .loaded {
                Text(visibleFormats.count == 1
                     ? L10n.t("%d option", visibleFormats.count)
                     : L10n.t("%d options", visibleFormats.count))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
            }
            if case .failed = phase {
                Button(L10n.t("Retry")) { Task { await load(force: true) } }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .accessibilityLabel(L10n.t("Retry loading quality options"))
            }
        }
    }

    private var formatList: some View {
        AddListWell(maxHeight: 240) {
            LazyVStack(spacing: 2) {
                row(id: nil,
                    quality: L10n.t("Best available"),
                    detail: Text(L10n.t("Let yt-dlp choose — always a single ready-to-play file.")),
                    spokenDetail: L10n.t("Let yt-dlp choose — always a single ready-to-play file."),
                    trailing: nil)
                ForEach(visibleFormats) { format in
                    row(id: format.id,
                        quality: format.qualityLabel,
                        detail: MediaFormatDetail.text(for: format),
                        spokenDetail: MediaFormatDetail.joined(for: format),
                        trailing: sizeText(for: format))
                }
            }
        }
    }

    private func row(id: String?, quality: String, detail: Text, spokenDetail: String,
                     trailing: String?) -> some View {
        let isSelected = id == selectedID
        return Button {
            selectedID = id
            onSelect(id.flatMap { chosen in formats.first { $0.id == chosen } })
        } label: {
            HStack(spacing: Studio.Space.m) {
                AddRadioGlyph(isOn: isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quality)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                    detail
                        .studioFont(.tiny)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Studio.Space.s)
                if let trailing {
                    Text(trailing)
                        .studioFont(.mono)
                        .foregroundStyle(Studio.Palette.ink2)
                }
            }
        }
        .buttonStyle(AddOptionRowStyle(isOn: isSelected))
        .a11yGroup(label: quality, value: A11y.sentence(spokenDetail, trailing))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
        if let seed {
            switch seed {
            case .loading: phase = .loading
            case .loaded(let listed): formats = listed; phase = .loaded
            case .failed(let message): phase = .failed(message)
            }
            if formats.allSatisfy({ !$0.isSelfContained }) { showSeparateTracks = true }
            return
        }
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

/// A format's second line: container, codecs, the track marker and yt-dlp's note.
enum MediaFormatDetail {
    private static func pieces(for format: MediaFormat) -> (before: [String], marker: String?, after: [String]) {
        var before: [String] = [format.ext]
        let codecs = [format.vcodec, format.acodec]
            .compactMap { $0 }
            .map { $0.split(separator: ".").first.map(String.init) ?? $0 }
        if !codecs.isEmpty { before.append(codecs.joined(separator: " + ")) }
        var marker: String?
        if format.isVideoOnly { marker = L10n.t("no sound — merged with an audio track") }
        if format.isAudioOnly { marker = L10n.t("audio only") }
        return (before, marker, format.note.isEmpty ? [] : [format.note])
    }

    /// The plain sentence, as VoiceOver reads it.
    static func joined(for format: MediaFormat) -> String {
        let parts = pieces(for: format)
        return (parts.before + [parts.marker].compactMap { $0 } + parts.after).joined(separator: " · ")
    }

    /// The same text with the "no sound" marker in the warning colour.
    static func text(for format: MediaFormat) -> Text {
        let parts = pieces(for: format)
        var text = Text(parts.before.joined(separator: " · "))
        if let marker = parts.marker {
            let tint = format.isVideoOnly ? Studio.Palette.warn : Studio.Palette.ink2
            text = text + Text(verbatim: " · ") + Text(marker).foregroundStyle(tint)
        }
        if !parts.after.isEmpty {
            text = text + Text(verbatim: " · " + parts.after.joined(separator: " · "))
        }
        return text
    }
}
