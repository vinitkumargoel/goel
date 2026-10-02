import SwiftUI
import GoelCore

/// Media mode for a video page: five presets up front, the full format table under
/// "More formats…". Lists the page's formats once and hands them to the table.
struct MediaPresetPicker: View {
    let pageURL: URL
    let maxHeight: Int
    @Binding var preset: MediaPreset?
    @Binding var chosenFormat: MediaFormat?
    /// Whether yt-dlp listed formats: only then must the caller resolve through yt-dlp.
    var onListed: (Bool) -> Void
    /// Snapshot seam: a listing to show instead of asking yt-dlp. Nil in the app.
    var seed: AddListingSeed<[MediaFormat]>?

    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var formats: [MediaFormat] = []
    @State private var showMore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            HStack(spacing: Studio.Space.xs) {
                Image(systemName: "play.rectangle")
                    .studioFont(.ui, size: 12, weight: 650)
                    .foregroundStyle(Studio.Palette.accent)
                    .a11yDecorative()
                AddFieldLabel(L10n.t("Download as"))
            }
            switch phase {
            case .loading: loadingRow
            case .failed(let message): failureRow(message)
            case .loaded:
                MediaPresetGrid(maxHeight: maxHeight, selection: presetBinding)
                moreFormats
            }
        }
        .task(id: pageURL) { await load() }
        .onDisappear { onListed(false) }
    }

    /// Picking a preset clears a raw format, and the other way round, so only one applies.
    private var presetBinding: Binding<MediaPreset?> {
        Binding(get: { preset }, set: { preset = $0; if $0 != nil { chosenFormat = nil } })
    }

    private var moreFormats: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            Button {
                addFlowAnimate(reduceMotion: reduceMotion, stillFrames: stillFrames) { showMore.toggle() }
            } label: {
                Label(L10n.t("More formats…"), systemImage: showMore ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.studio(.ghost, size: .small))
            .accessibilityValue(showMore ? L10n.t("Expanded") : L10n.t("Collapsed"))
            if showMore {
                MediaFormatPicker(pageURL: pageURL, preloadedFormats: formats) { format in
                    chosenFormat = format
                    preset = format == nil ? .best : nil
                }
            }
        }
    }

    private var loadingRow: some View {
        AddLoadingLine(text: L10n.t("Asking yt-dlp what’s available…"),
                       accessibilityLabel: L10n.t("Asking yt-dlp what’s available"))
    }

    private func failureRow(_ message: String) -> some View {
        AddCallout(tone: .warn, symbol: "exclamationmark.triangle.fill", message: message) {
            Button(L10n.t("Retry")) { Task { await load() } }
                .buttonStyle(.studio(.secondary, size: .small))
                .accessibilityLabel(L10n.t("Retry loading quality options"))
        }
    }

    private func load() async {
        if let seed {
            switch seed {
            case .loading: phase = .loading
            case .loaded(let listed): formats = listed; phase = .loaded
            case .failed(let message): phase = .failed(message)
            }
            return
        }
        phase = .loading
        let outcome = await YtDlpResolver.listFormats(pageURL)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .formats(let listed):
            formats = listed
            phase = listed.isEmpty ? .failed(L10n.t("yt-dlp found no formats on that page.")) : .loaded
        case .failed(let message):
            formats = []
            phase = .failed(message)
        }
        onListed(phase == .loaded)
    }
}

/// The five preset tiles; also used by the playlist checklist, where one preset covers every item.
struct MediaPresetGrid: View {
    let maxHeight: Int
    @Binding var selection: MediaPreset?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Studio.Space.s), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Studio.Space.s) {
            ForEach(MediaPreset.allCases) { preset in
                MediaPresetTile(preset: preset, maxHeight: maxHeight,
                                isSelected: selection == preset) { selection = preset }
            }
        }
    }
}

private struct MediaPresetTile: View {
    let preset: MediaPreset
    let maxHeight: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                HStack(spacing: Studio.Space.xs) {
                    Text(preset.title(maxHeight: maxHeight))
                        .studioFont(.title3.size(15))
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: preset.symbol)
                        .studioFont(.ui, size: 12, weight: 650)
                        .foregroundStyle(isSelected ? Studio.Palette.accent : Studio.Palette.ink3)
                        .a11yDecorative()
                }
                Text(preset.detail)
                    .studioFont(.tiny)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Studio.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovered && !isSelected ? Studio.Palette.well : Studio.Palette.card)
                .studioElevation(.raised))
            .overlay(shape.strokeBorder(isSelected ? Studio.Palette.accent : Studio.Palette.cardEdge,
                                        lineWidth: isSelected ? 1.5 : 1))
            .background {
                if isSelected { shape.inset(by: -3).fill(Studio.Palette.accentSoft) }
            }
            .studioButtonFocusRing(shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.studioPlain)
        .onHover { hovered = $0 }
        .a11yGroup(label: preset.title(maxHeight: maxHeight), value: preset.detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
