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

    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var formats: [MediaFormat] = []
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Download as"), systemImage: "play.rectangle")
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
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
        DisclosureGroup(isExpanded: $showMore) {
            MediaFormatPicker(pageURL: pageURL, preloadedFormats: formats) { format in
                chosenFormat = format
                preset = format == nil ? .best : nil
            }
            .padding(.top, 6)
        } label: {
            Text(L10n.t("More formats…"))
                .scaledFont(size: Theme.TextSize.meta, weight: .semibold)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).a11yDecorative()
            Text(L10n.t("Asking yt-dlp what’s available…"))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
        }
        .a11yGroup(label: L10n.t("Asking yt-dlp what’s available"))
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L10n.t("Retry")) { Task { await load() } }
                .buttonStyle(.link)
                .accessibilityLabel(L10n.t("Retry loading quality options"))
        }
    }

    private func load() async {
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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: preset.symbol)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(width: 18)
                    .a11yDecorative()
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.title(maxHeight: maxHeight))
                        .scaledFont(size: Theme.TextSize.meta, weight: .semibold)
                    Text(preset.detail)
                        .scaledFont(size: Theme.TextSize.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                .stroke(isSelected ? Theme.accent : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(label: preset.title(maxHeight: maxHeight), value: preset.detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
