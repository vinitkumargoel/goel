import SwiftUI
import AppKit
import GoelCore

/// ⌘K: every action and settings pane in one search field. Commands are grouped by what they act
/// on; ↑/↓ move, ↩ runs, esc closes.
struct CommandPalette: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query: String
    /// Index into the flattened match list; re-clamped, or a shrinking list leaves it past the end.
    @State private var highlighted: Int = 0
    @FocusState private var searchFocused: Bool

    /// `query` is for previews and snapshots; the app opens the palette empty.
    init(query: String = "") {
        _query = State(initialValue: query)
    }

    private var catalog: CommandPaletteCatalog {
        CommandPaletteCatalog(vm: vm, openSettings: { openSettings() })
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    /// What is listed, in display order: grouped as declared when empty, else ranked and grouped
    /// by each group's best match.
    private var matches: [PaletteCommand] {
        guard !needle.isEmpty else { return catalog.commands }
        return PaletteRanking.grouped(PaletteRanking.ranked(catalog.searchable(needle), needle: needle))
    }

    var body: some View {
        let matches = self.matches
        let total = catalog.commands.count
        VStack(spacing: 0) {
            searchField(matches)
            StudioDivider()
            if matches.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: L10n.t("No matching command"),
                                 message: L10n.t("Try “rss”, “mirror”, “watch folder”, or “cookies”."))
                    .frame(height: 300)
            } else {
                resultList(matches)
            }
            legend(matchCount: matches.count, total: total)
        }
        .frame(width: 640)
        .background(Studio.Palette.sheet)
        .onAppear { searchFocused = true }
    }

    // MARK: Search field

    private func searchField(_ matches: [PaletteCommand]) -> some View {
        HStack(spacing: Studio.Space.m) {
            Image(systemName: "command")
                .studioFont(.ui, size: 18, weight: 650)
                .foregroundStyle(Studio.Palette.accent)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            TextField(L10n.t("Search actions and settings…"), text: $query)
                .textFieldStyle(.plain)
                .studioFont(.omnibox)
                .foregroundStyle(Studio.Palette.ink)
                .focused($searchFocused)
                .onSubmit { runHighlighted(matches) }
                .onChange(of: query) { _, _ in highlighted = 0 }
                .accessibilityLabel(L10n.t("Search actions and settings"))
                .accessibilityHint(L10n.t("Use the up and down arrow keys to move through results, return to run."))
                .accessibilityValue(matches.indices.contains(highlighted)
                                    ? L10n.t("%1$@ results, %2$@ selected",
                                             String(matches.count), matches[highlighted].title)
                                    : L10n.t("No results"))
            if !query.isEmpty {
                StudioIconButton("xmark.circle.fill", label: L10n.t("Clear search"), size: .small) {
                    query = ""
                    searchFocused = true
                }
            }
            StudioKeyCaps("esc")
        }
        .padding(.leading, 18)
        .padding(.trailing, Studio.Space.ml)
        .frame(minHeight: 58)
        // Arrow keys must be handled on the field, not the list, or they move the text cursor.
        .onKeyPress(.downArrow) { move(by: 1, count: matches.count) }
        .onKeyPress(.upArrow) { move(by: -1, count: matches.count) }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    // MARK: Results

    private func resultList(_ matches: [PaletteCommand]) -> some View {
        let sections = PaletteRanking.sections(matches)
        let selectionName = vm.selectedServer == nil && vm.selectedTasks.count == 1
            ? vm.selectedTasks.first?.name : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                        sectionHeader(section.group, selectionName: selectionName, isFirst: sectionIndex == 0)
                        ForEach(section.commands) { command in
                            let index = matches.firstIndex { $0.id == command.id } ?? 0
                            PaletteRow(command: command, needle: needle, isHighlighted: index == highlighted) {
                                run(command)
                            }
                            .id(command.id)
                            .onHover { if $0 { highlighted = index } }
                        }
                    }
                }
                .padding(Studio.Space.xs)
            }
            .frame(height: 380)
            .onChange(of: highlighted) { _, new in
                guard matches.indices.contains(new) else { return }
                if reduceMotion {
                    proxy.scrollTo(matches[new].id)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(matches[new].id) }
                }
            }
        }
    }

    private func sectionHeader(_ group: PaletteCommand.Group, selectionName: String?, isFirst: Bool) -> some View {
        let title = group == .selection && selectionName != nil
            ? L10n.t("%1$@ · %2$@", group.title, selectionName ?? "")
            : group.title
        return WindowsEyebrow(title)
            .truncationMode(.middle)
            .padding(.horizontal, Studio.Space.sm)
            .padding(.top, isFirst ? Studio.Space.s : Studio.Space.sm)
            .padding(.bottom, Studio.Space.xxs)
    }

    // MARK: Legend

    private func legend(matchCount: Int, total: Int) -> some View {
        HStack(spacing: Studio.Space.ml) {
            legendKey(["↑", "↓"], L10n.t("Navigate"))
            legendKey(["↩"], L10n.t("Run"))
            legendKey(["esc"], L10n.t("Close"))
            Spacer(minLength: Studio.Space.s)
            Group {
                if needle.isEmpty {
                    Text(L10n.t("Try “rss”, “retry” or “theme”"))
                } else {
                    Text(L10n.t("%1$@ of %2$@", String(matchCount), String(total)))
                        .monospacedDigit()
                }
            }
            .studioFont(.caption)
            .foregroundStyle(Studio.Palette.ink3)
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.vertical, Studio.Space.sm)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
        .accessibilityHidden(true)
    }

    private func legendKey(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: Studio.Space.xs) {
            StudioKeyCaps(keys: keys)
            Text(label).studioFont(.caption).foregroundStyle(Studio.Palette.ink2)
        }
    }

    // MARK: Actions

    private func move(by delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func runHighlighted(_ matches: [PaletteCommand]) {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    /// Dismiss before running: AppKit won't stack a sheet on a window still showing this one.
    private func run(_ command: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async(execute: command.run)
    }
}

/// One command: glyph, title with the typed text in bold, where it lives, and its shortcut.
private struct PaletteRow: View {
    let command: PaletteCommand
    let needle: String
    let isHighlighted: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100

    var body: some View {
        Button(action: action) {
            HStack(spacing: Studio.Space.m) {
                Image(systemName: command.symbol)
                    .studioFont(.ui, size: 14, weight: 600)
                    .foregroundStyle(isHighlighted ? Studio.Palette.accent : Studio.Palette.ink3)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlightedTitle)
                        .studioFont(.body)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(command.subtitle)
                        .studioFont(.caption)
                        // Subtitles say where a command lives: secondary, not tertiary.
                        .foregroundStyle(Studio.Palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Studio.Space.sm)
                if let shortcut = command.shortcut {
                    StudioKeyCaps(shortcut)
                }
            }
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Studio.Palette.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.segment, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(command.title, command.group.title))
        .accessibilityValue(command.subtitle)
        .accessibilityHint(command.shortcut.map { L10n.t("Keyboard shortcut %@.", $0) } ?? "")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// The first occurrence of what was typed, drawn bold (`<b>Pa</b>use Selected`).
    private var highlightedTitle: AttributedString {
        var text = AttributedString(command.title)
        guard !needle.isEmpty, let range = text.range(of: needle, options: .caseInsensitive) else { return text }
        text[range].font = StudioFonts.font(.ui, size: Studio.TextStyle.body.size * factor / 100, weight: 750)
        return text
    }
}
