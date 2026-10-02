import SwiftUI
import GoelCore

/// Rules: "when a new download looks like this, put it there and treat it so". Rules run in order
/// at add time, before the default folder rule; the first match wins.
struct RulesSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var editing: AutoSortRule?
    @State private var history: [AutoSortCandidate]
    /// Snapshots pass a fixed history and skip the database read.
    private let loadsHistory: Bool

    init(history: [AutoSortCandidate]? = nil) {
        _history = State(initialValue: history ?? [])
        loadsHistory = history == nil
    }

    private var rules: [AutoSortRule] { vm.settings.autoSortRules }

    var body: some View {
        SettingsPane(title: L10n.t("Rules"),
                     subtitle: L10n.t("Sort new downloads by name, type, site or size."),
                     fillsWidth: true) {
            Button(L10n.t("Add Rule…"), systemImage: "plus") { editing = RuleEditorSheet.blankRule() }
                .buttonStyle(.studio(.primary, size: .small))
        } content: {
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                HStack(spacing: Studio.Space.s) {
                    Text(L10n.t("Download rules"))
                        .studioFont(.eyebrow)
                        .foregroundStyle(Studio.Palette.ink3)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Studio.Space.s)
                    Text(L10n.t("Rules are checked top to bottom; the first match applies."))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                }
                .padding(.horizontal, Studio.Space.xxs)
                if rules.isEmpty {
                    emptyRules
                } else {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        RuleCard(rule: rule, matches: AutoSortRules.matchCount(of: rule, in: history),
                                 isFirst: index == 0, isLast: index == rules.count - 1,
                                 onToggle: { enabled in setEnabled(rule.id, enabled) },
                                 onEdit: { editing = rule },
                                 onMove: { offset in move(rule.id, by: offset) },
                                 onDelete: { delete(rule.id) })
                    }
                }
            }
        }
        .task {
            guard loadsHistory else { return }
            history = await AutoSortRulePresentation.candidates(from: vm.fetchHistory())
        }
        .sheet(item: $editing) { rule in
            RuleEditorSheet(rule: rule, history: history) { saved in save(saved) }
        }
    }

    private var emptyRules: some View {
        StudioCard {
            StudioEmptyState(symbol: "line.3.horizontal.decrease.circle",
                             title: L10n.t("Sort downloads automatically"),
                             message: L10n.t("No rules yet. A rule can send .dmg files to Installers, cap a slow site, or open videos when done.")) {
                Button(L10n.t("Add Rule…"), systemImage: "plus") { editing = RuleEditorSheet.blankRule() }
                    .buttonStyle(.studio(.secondary, size: .small))
            }
            .padding(-Studio.Space.s)
        }
    }

    private func save(_ rule: AutoSortRule) {
        vm.update { settings in
            if let index = settings.autoSortRules.firstIndex(where: { $0.id == rule.id }) {
                settings.autoSortRules[index] = rule
            } else {
                settings.autoSortRules.append(rule)
            }
        }
    }

    private func setEnabled(_ id: UUID, _ enabled: Bool) {
        vm.update { settings in
            guard let index = settings.autoSortRules.firstIndex(where: { $0.id == id }) else { return }
            settings.autoSortRules[index].enabled = enabled
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        vm.update { $0.autoSortRules = AutoSortRulePresentation.moving(id, by: offset, in: $0.autoSortRules) }
    }

    private func delete(_ id: UUID) {
        vm.update { $0.autoSortRules.removeAll { $0.id == id } }
    }
}

/// One rule (`.mcard`): name and plain-language summary, how much of the history it catches,
/// reorder / edit / delete, and its on-off switch.
private struct RuleCard: View {
    let rule: AutoSortRule
    let matches: Int
    let isFirst: Bool
    let isLast: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(rule.name)
                        .studioFont(.cardTitle.size(13))
                        .foregroundStyle(rule.enabled ? Studio.Palette.ink : Studio.Palette.ink3)
                        .lineLimit(1)
                    Text(AutoSortRulePresentation.summary(rule))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(2)
                    Text(L10n.t("%d in history", matches))
                        .studioFont(.monoSmall)
                        .foregroundStyle(matches > 0 ? Studio.Palette.accent : Studio.Palette.ink3)
                        .padding(.top, Studio.Space.hair)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("Edit rule"))
            .accessibilityLabel(rule.name)
            .accessibilityValue(AutoSortRulePresentation.summary(rule))
            .accessibilityHint(L10n.t("Edit rule"))

            HStack(spacing: Studio.Space.hair) {
                StudioIconButton("chevron.up", label: L10n.t("Move up"), size: .small) { onMove(-1) }
                    .disabled(isFirst)
                StudioIconButton("chevron.down", label: L10n.t("Move down"), size: .small) { onMove(1) }
                    .disabled(isLast)
                StudioIconButton("pencil", label: L10n.t("Edit rule"), size: .small, action: onEdit)
                StudioIconButton("trash", label: L10n.t("Delete rule"), size: .small, action: onDelete)
            }
            .opacity(hovered ? 1 : 0.75)

            Toggle(isOn: Binding(get: { rule.enabled }, set: onToggle)) { EmptyView() }
                .toggleStyle(.studioSwitch)
                .accessibilityLabel(L10n.t("Enable rule %@", rule.name))
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, 11)
        .studioSurface(.card, radius: Studio.Radius.compactCard)
        .onHover { hovered = $0 }
    }
}
