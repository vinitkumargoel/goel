import SwiftUI
import GoelCore

/// The one box for everything: typing filters the list through the view model's search (with the
/// `host:` token), a pasted or typed URL, magnet or .m3u8 turns into a recognised-link row that
/// starts the Add flow, ⌘K opens the command palette, and the copied-link suggestion sits inside it.
struct MainOmnibox<Accessory: View>: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.omnibox, style: .continuous)
        let focused = isFocused.wrappedValue
        let input = OmniboxInput.classify(text)
        VStack(spacing: 0) {
            inputRow(input)
            if !input.links.isEmpty {
                StudioOmniboxSuggestion {
                    OmniboxRecognisedRow(sources: input.links) { addLinks() }
                }
            }
            if let link = vm.clipboardSuggestion {
                StudioOmniboxSuggestion {
                    OmniboxClipboardRow(link: link)
                }
            }
            accessory()
        }
        .background(shape.fill(Studio.Palette.card).studioElevation(focused ? .floating : .card))
        .overlay(shape.strokeBorder(focused ? Studio.Palette.accentLine : Studio.Palette.cardEdge, lineWidth: 1))
        .background {
            if focused { shape.inset(by: -4).fill(Studio.Palette.accentSoft) }
        }
    }

    private func inputRow(_ input: OmniboxInput) -> some View {
        HStack(spacing: Studio.Space.m) {
            Image(systemName: symbol(for: input))
                .font(StudioFonts.font(.ui, size: 18, weight: 650))
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            TextField(L10n.t("Paste a link, magnet or stream — or search"), text: $text)
                .textFieldStyle(.plain)
                .studioFont(.omnibox)
                .foregroundStyle(Studio.Palette.ink)
                .focused(isFocused)
                .onSubmit(submit)
                .onExitCommand {
                    // Escape clears, then a second Escape hands the keyboard back to the list.
                    if text.isEmpty { isFocused.wrappedValue = false } else { text = "" }
                }
                .accessibilityLabel(L10n.t("Search downloads"))
                .help(ShortcutHint.help(L10n.t("Search downloads (host:example.com narrows to a site)"), "⌘F"))
            trailing(input)
        }
        .padding(.leading, 18)
        .padding(.trailing, Studio.Space.sm)
        .frame(minHeight: 58)
    }

    private func symbol(for input: OmniboxInput) -> String {
        switch input {
        case .empty: return "plus"
        case .search: return "magnifyingglass"
        case .links: return "link"
        }
    }

    @ViewBuilder
    private func trailing(_ input: OmniboxInput) -> some View {
        switch input {
        case .empty:
            OmniboxPaletteKeycap()
        case .search:
            StudioChip(L10n.t("Search downloads"), symbol: "line.3.horizontal.decrease", size: .small)
                .accessibilityHidden(true)
            clearButton
        case .links:
            clearButton
        }
    }

    private var clearButton: some View {
        StudioIconButton("xmark.circle.fill", label: L10n.t("Clear search"), size: .small) {
            text = ""
            // Back to the field, so the next search can be typed straight away.
            isFocused.wrappedValue = true
        }
    }

    private func submit() {
        if !OmniboxInput.classify(text).links.isEmpty { addLinks() }
    }

    /// The Add sheet, prefilled: one link gets its preview, several get the review step.
    private func addLinks() {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else { return }
        text = ""
        vm.addSheetPrefill = lines
        vm.isAddSheetPresented = true
    }
}

extension MainOmnibox where Accessory == EmptyView {
    init(text: Binding<String>, isFocused: FocusState<Bool>.Binding) {
        self.init(text: text, isFocused: isFocused, accessory: { EmptyView() })
    }
}

/// The ⌘K cap at the omnibox's end. Once the queue has rows the first-run hints are gone, so this
/// is the palette's on-screen entry point.
struct OmniboxPaletteKeycap: View {
    @State private var hovering = false

    var body: some View {
        Button {
            CommandPaletteBus.toggle()
        } label: {
            StudioKeyCaps("⌘K")
                .opacity(hovering ? 1 : 0.9)
                .overlay {
                    if hovering {
                        RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous)
                            .strokeBorder(Studio.Palette.accentLine, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.t("Command palette · ⌘K"))
        .a11yButton(L10n.t("Command palette, Command K"))
    }
}

/// "HTTP · releases.ubuntu.com → Add": what the omnibox recognised in the typed or pasted text.
struct OmniboxRecognisedRow: View {
    let sources: [DownloadSource]
    let add: () -> Void

    /// The file it points at; the whole link when there is no file name (a magnet, a bare host).
    static func name(of source: DownloadSource) -> String {
        let file = OmniboxInput.fileName(of: source)
        return file.isEmpty || file == "/" ? source.locator : file
    }

    var body: some View {
        let first = sources[0]
        let many = sources.count > 1
        StudioFileArtwork(kind: StudioArtKind(OmniboxInput.fileType(of: first)), size: .s)
        VStack(alignment: .leading, spacing: 1) {
            Text(many ? L10n.t("%d links recognised", sources.count) : L10n.t("Recognised link"))
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.accent)
            Text(many ? L10n.t("%1$@ and %2$d more", Self.name(of: first), sources.count - 1) : Self.name(of: first))
                .studioFont(.body)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        StudioKindBadge(kind: first.kind)
        Text(OmniboxInput.host(of: first))
            .studioFont(.monoSmall)
            .foregroundStyle(Studio.Palette.ink3)
            .lineLimit(1)
            .frame(maxWidth: 180, alignment: .trailing)
            .accessibilityHidden(true)
        Button(many ? L10n.t("Review & Add") : L10n.t("Add"), systemImage: "arrow.right", action: add)
            .buttonStyle(.studio(.primary, size: .small))
            .help(ShortcutHint.help(L10n.t("Add download"), "↩"))
            .accessibilityLabel(many ? L10n.t("Review and add %d links", sources.count)
                                     : L10n.t("Add %@", OmniboxInput.summary(of: first)))
    }
}

/// The copied-link suggestion, inside the omnibox rather than as a banner: Options… opens the Add
/// sheet with the link, Add queues it (Choose quality… for a video page), ✕ dismisses it.
struct OmniboxClipboardRow: View {
    @EnvironmentObject private var vm: AppViewModel
    let link: String

    var body: some View {
        let source = AppViewModel.parseSource(link)
        let kind: StudioArtKind = vm.suggestionIsMediaPage ? .video
            : source.map { StudioArtKind(OmniboxInput.fileType(of: $0)) } ?? .other
        StudioFileArtwork(kind: kind, size: .s)
        VStack(alignment: .leading, spacing: 1) {
            Text(vm.suggestionIsMediaPage ? L10n.t("Copied a video page")
                 : vm.suggestionIsFromBrowser ? L10n.t("Link from your browser") : L10n.t("Copied link detected"))
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.accent)
            Text(link)
                .studioFont(.body)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let source, !vm.suggestionIsMediaPage {
            StudioKindBadge(kind: source.kind)
        }
        if !vm.suggestionIsMediaPage {
            Button(L10n.t("Options…")) { vm.openClipboardSuggestionInAddSheet() }
                .buttonStyle(.studio(.ghost, size: .small))
                .accessibilityLabel(L10n.t("Choose where and how to save the copied link"))
        }
        Button(vm.suggestionIsMediaPage ? L10n.t("Choose quality…") : L10n.t("Add"), systemImage: "arrow.right") {
            vm.acceptClipboardSuggestion()
        }
        .buttonStyle(.studio(.primary, size: .small))
        .accessibilityLabel(vm.suggestionIsMediaPage
                            ? L10n.t("Choose a quality for the copied video page")
                            : vm.suggestionIsFromBrowser
                            ? L10n.t("Add the link from your browser to downloads")
                            : L10n.t("Add copied link to downloads"))
        StudioIconButton("xmark", label: L10n.t("Dismiss copied link suggestion"), size: .small) {
            vm.dismissClipboardSuggestion()
        }
    }
}
