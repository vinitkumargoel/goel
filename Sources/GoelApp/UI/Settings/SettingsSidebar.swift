import SwiftUI
import GoelCore

/// The pane list (`.set-nav`): "Search settings", matching rows while searching, then the five
/// groups. ↑/↓ move between the visible panes.
struct SettingsSidebar: View {
    @Binding var selection: SettingsView.Pane
    @Binding var searchText: String
    let matches: [SettingsView.Pane]

    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(text: $searchText)
                .padding(.horizontal, Studio.Space.m)
                .padding(.top, Studio.Space.ml)
                .padding(.bottom, Studio.Space.xs)

            if matches.isEmpty {
                Text(L10n.t("No settings match “%@”.", searchText.trimmingCharacters(in: .whitespaces)))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Studio.Space.xl)
                    .padding(.vertical, Studio.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        rowHits
                        ForEach(SettingsView.Pane.Group.allCases) { group in
                            let panes = group.panes.filter(matches.contains)
                            if !panes.isEmpty {
                                groupHeader(group.title)
                                ForEach(panes) { pane in
                                    SettingsSidebarRow(pane: pane, isSelected: pane == selection,
                                                       showsFocusRing: listFocused && pane == selection) {
                                        selection = pane
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Studio.Space.m)
                    .padding(.bottom, Studio.Space.ml)
                }
                .scrollContentBackground(.hidden)
                .focusable()
                .focused($listFocused)
                // The system ring would circle the whole list; the selected row draws its own.
                .focusEffectDisabled()
                .onMoveCommand(perform: move)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .studioRailBackground()
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .studioFont(.eyebrow)
            .foregroundStyle(Studio.Palette.ink3)
            .padding(.horizontal, Studio.Space.sm)
            .padding(.top, Studio.Space.sm)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    /// Individual settings that match, each labelled with its pane: "sleep" finds the row, not
    /// just the three panes it could be on.
    @ViewBuilder
    private var rowHits: some View {
        let hits = SettingsSearch.rows(matching: searchText, limit: 8)
        if !hits.isEmpty {
            groupHeader(L10n.t("Matching settings"))
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                SettingsRowHit(title: hit.title, pane: hit.pane) { selection = hit.pane }
            }
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let visible = SettingsView.Pane.Group.allCases.flatMap(\.panes).filter(matches.contains)
        guard let index = visible.firstIndex(of: selection) else {
            if let first = visible.first { selection = first }
            return
        }
        switch direction {
        case .up where index > 0: selection = visible[index - 1]
        case .down where index < visible.count - 1: selection = visible[index + 1]
        default: break
        }
    }
}

/// One pane in the list (`.sn`): glyph and name; the selected one sits on a card.
private struct SettingsSidebarRow: View {
    let pane: SettingsView.Pane
    let isSelected: Bool
    /// The list has keyboard focus and ↑/↓ move this row.
    var showsFocusRing = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous)
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                Image(systemName: pane.symbol)
                    .studioFont(.ui, size: 13.5, weight: 600)
                    .foregroundStyle(isSelected ? Studio.Palette.accent : Studio.Palette.ink3)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(pane.title)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(isSelected || hovered ? Studio.Palette.ink : Studio.Palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(height: 30)
            .background {
                if isSelected {
                    shape.fill(Studio.Palette.card).studioElevation(.card)
                } else if hovered {
                    shape.fill(Studio.Palette.segment)
                }
            }
            .studioFocusRing(showsFocusRing, shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A matching setting while searching: its title, and the pane it lives on.
private struct SettingsRowHit: View {
    let title: String
    let pane: SettingsView.Pane
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .studioFont(.ui, size: 11, weight: 650)
                    .foregroundStyle(Studio.Palette.accent)
                    .frame(width: 18)
                    .padding(.top, Studio.Space.hair)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .studioFont(.body)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(2)
                    Text(pane.title)
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, Studio.Space.xs)
            .background(hovered ? Studio.Palette.segment : .clear,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.artSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(L10n.t("%1$@, in %2$@", title, pane.title))
    }
}

/// "Search settings" (`.field.sm` with a magnifier); Esc or the clear button empties it.
private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        StudioFocusedField(size: .small) { focus in
            HStack(spacing: Studio.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .studioFont(.ui, size: 12, weight: 600)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(L10n.t("Search settings"))
                            .foregroundStyle(Studio.Palette.ink3)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .focused(focus)
                        .onExitCommand { text = "" }
                        .accessibilityLabel(L10n.t("Search settings"))
                }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Clear search"))
                    .a11yButton(L10n.t("Clear search"))
                }
            }
        }
    }
}
