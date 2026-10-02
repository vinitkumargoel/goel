import SwiftUI
import GoelCore

/// Step 1: paste or drop links. One link previews next; several go to review.
struct AddInputStep: View {
    @ObservedObject var model: AddSheetModel
    /// The drag highlight; a snapshot can start with it on.
    @State var isDropTargeted = false

    private var canContinue: Bool {
        !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AddFlowHeader(title: L10n.t("Add download"), symbol: model.headerSymbol) {
                StudioPill(L10n.t("Step 1 of 2"), showsDot: false)
            }
            VStack(alignment: .leading, spacing: Studio.Space.ml) {
                linkField
                AddRecognizedList(sources: model.recognizedSources)
                dropZone
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xl)
            footer
        }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            HStack {
                AddFieldLabel(L10n.t("URL, magnet, or .m3u8 stream"))
                Spacer()
                if let pasted = model.pastedText, pasted == model.text {
                    AddPastedNote { model.clearPasted() }
                }
            }
            AddTextArea(text: $model.text,
                        placeholder: L10n.t("Paste links here, one per line"),
                        height: 120,
                        accessibilityLabel: L10n.t("URL, magnet, or m3u8 stream"),
                        accessibilityHint: L10n.t("Paste one link per line to add several at once."),
                        isInvalid: model.inputError != nil)
            if let error = model.inputError {
                AddStatusLine(symbol: "exclamationmark.triangle.fill", text: error, tone: .warn, tintsText: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.t("Error. %@", error))
            } else {
                AddHelpText(L10n.t("Paste several lines to add them all at once (batch). Patterns expand too: file[01-20].zip or file.{iso,sig}. A single link is previewed before it starts.")
                            + " " + L10n.t("Press ⌘↩ to continue."))
            }
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
        return HStack(spacing: Studio.Space.sm) {
            Image(systemName: "arrow.down.to.line")
                .font(StudioFonts.font(.ui, size: 16, weight: 650))
                .a11yDecorative()
            Text(MarkdownText.attributed(L10n.t("Drag a URL or **.torrent** file here")))
                .studioFont(.small)
        }
        // Targeted: a stronger tint with ink text — accent text on `accentLine` washed out in dark.
        .foregroundStyle(isDropTargeted ? Studio.Palette.ink : Studio.Palette.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Studio.Space.l)
        .background(shape.fill(isDropTargeted ? Studio.Palette.accentLine : Studio.Palette.accentSoft))
        .overlay(shape.strokeBorder(isDropTargeted ? Studio.Palette.accent : Studio.Palette.accentLine,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { model.handleDrop($0) }
    }

    private var footer: some View {
        AddFlowFooter {
            Spacer()
            Button(L10n.t("Cancel")) { model.finish() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.studio(.secondary))
            // ⌘↩, not ↩: the focused editor takes a plain Return as a new line.
            Button { model.continueTapped() } label: {
                HStack(spacing: Studio.Space.xs) {
                    Text(L10n.t("Continue"))
                    Text(verbatim: "⌘↩")
                        .studioFont(.keyCap)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Studio.Palette.onAccent.opacity(0.6), lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.studio(.primary))
            .disabled(!canContinue)
            .help(L10n.t("Continue (⌘↩)"))
        }
    }
}

/// "Recognized · 3 downloads": what the box parses to so far, before anything is committed.
struct AddRecognizedList: View {
    let sources: [DownloadSource]
    private let shown = 4

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                Text(sources.count == 1 ? L10n.t("Recognized · 1 download")
                                        : L10n.t("Recognized · %d downloads", sources.count))
                    .studioFont(.eyebrow)
                    .foregroundStyle(Studio.Palette.ink3)
                ForEach(Array(sources.prefix(shown).enumerated()), id: \.offset) { _, source in
                    HStack(spacing: Studio.Space.s) {
                        HStack(spacing: 0) {
                            StudioKindBadge(kind: source.kind)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 44)
                        Text(LinkReview.name(for: source))
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Studio.Space.s)
                        Text(LinkReview.host(for: source))
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if sources.count > shown {
                    Text(L10n.t("and %d more", sources.count - shown))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
        }
    }
}

/// While the link's name and size are fetched. Continue anyway skips the preview.
struct AddResolvingStep: View {
    @ObservedObject var model: AddSheetModel

    var body: some View {
        VStack(spacing: 0) {
            AddFlowHeader(title: L10n.t("Review & start"), eyebrow: L10n.t("Step 2 of 2"),
                          symbol: model.headerSymbol)
            VStack(spacing: Studio.Space.ml) {
                StudioProgressArc(fraction: nil, diameter: 46, accessibilityLabel: L10n.t("Fetching details"))
                Text(L10n.t("Fetching details…"))
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("Reading the file name and size. Magnet links ask peers for the file list, which can take a few seconds."))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Studio.Space.sm) {
                    Button(L10n.t("Cancel")) { model.cancelResolving() }
                        .buttonStyle(.studio(.secondary))
                    Button(L10n.t("Continue anyway")) { model.continueWithoutPreview() }
                        .buttonStyle(.studio(.primary))
                }
                .padding(.top, Studio.Space.xxs)
                Text(L10n.t("Continue anyway adds it straight to the queue — the name and size fill in as it starts."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Studio.Space.xl)
            .padding(.bottom, 36)
            .padding(.horizontal, Studio.Space.xl)
        }
    }
}
