import SwiftUI
import GoelCore

/// Settings › Rules: "when a new download looks like this, put it there and treat it so".
/// Rules run in order at add time, before the default folder rule; the first match wins.
struct RulesPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var editing: AutoSortRule?
    @State private var history: [AutoSortCandidate] = []

    private var rules: [AutoSortRule] { vm.settings.autoSortRules }

    var body: some View {
        PaneScaffold(title: L10n.t("Rules"),
                     subtitle: L10n.t("Sort new downloads by name, type, site or size.")) {
            SectionHeader(L10n.t("Download rules"))
            if rules.isEmpty {
                Text(L10n.t("No rules yet. A rule can send .dmg files to Installers, cap a slow site, or open videos when done."))
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    RuleRow(rule: rule, matches: AutoSortRules.matchCount(of: rule, in: history),
                            isFirst: index == 0, isLast: index == rules.count - 1,
                            onToggle: { enabled in setEnabled(rule.id, enabled) },
                            onEdit: { editing = rule },
                            onMove: { offset in move(rule.id, by: offset) },
                            onDelete: { delete(rule.id) })
                }
            }
            HStack {
                Button(L10n.t("Add Rule…")) { editing = RuleEditorSheet.blankRule() }
                Spacer()
                Text(L10n.t("Rules are checked top to bottom; the first match applies."))
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .task { history = await RulesPreview.candidates(from: vm.fetchHistory()) }
        .sheet(item: $editing) { rule in
            RuleEditorSheet(rule: rule, history: history) { saved in save(saved) }
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
        vm.update { $0.autoSortRules = RulesPreview.moving(id, by: offset, in: $0.autoSortRules) }
    }

    private func delete(_ id: UUID) {
        vm.update { $0.autoSortRules.removeAll { $0.id == id } }
    }
}

/// Pure helpers behind the pane, kept out of the views so they can be tested.
enum RulesPreview {

    static func candidates(from history: [HistoryEntry]) -> [AutoSortCandidate] {
        history.map { entry in
            AutoSortCandidate(fileName: entry.name, url: entry.locator,
                              host: URL(string: entry.locator)?.host?.lowercased() ?? "",
                              size: entry.totalBytes)
        }
    }

    static func moving(_ id: UUID, by offset: Int, in rules: [AutoSortRule]) -> [AutoSortRule] {
        guard let from = rules.firstIndex(where: { $0.id == id }) else { return rules }
        let to = min(max(from + offset, 0), rules.count - 1)
        guard to != from else { return rules }
        var result = rules
        result.insert(result.remove(at: from), at: to)
        return result
    }

    /// "If extension is any of dmg, pkg → ~/Installers, tag “apps”".
    static func summary(_ rule: AutoSortRule) -> String {
        let joiner = rule.match == .all ? L10n.t(" and ") : L10n.t(" or ")
        let conditions = rule.conditions.map { "\(fieldLabel($0.field)) \(operatorLabel($0.op)) \($0.value)" }
            .joined(separator: joiner)
        return actions(rule).isEmpty ? conditions
                                     : L10n.t("%1$@ → %2$@", conditions, actions(rule).joined(separator: ", "))
    }

    static func actions(_ rule: AutoSortRule) -> [String] {
        var parts: [String] = []
        if let folder = rule.folder, !folder.isEmpty { parts.append((folder as NSString).abbreviatingWithTildeInPath) }
        if let tag = rule.tag, !tag.isEmpty { parts.append(L10n.t("tag “%@”", tag)) }
        if let cap = rule.speedLimitBytesPerSec, cap > 0 { parts.append(L10n.t("cap %@", Double(cap).speedString)) }
        if let priority = rule.priority, priority != .normal { parts.append(priorityLabel(priority)) }
        if rule.startPaused { parts.append(L10n.t("start paused")) }
        if let whenDone = rule.whenDone, whenDone.isActionable { parts.append(WhenDonePicker.label(whenDone.kind)) }
        return parts
    }

    static func fieldLabel(_ field: AutoSortRule.Field) -> String {
        switch field {
        case .fileName: return L10n.t("File name")
        case .fileExtension: return L10n.t("Extension")
        case .domain: return L10n.t("Domain")
        case .url: return L10n.t("URL")
        case .size: return L10n.t("Size")
        }
    }

    static func operatorLabel(_ op: AutoSortRule.Operator) -> String {
        switch op {
        case .isEqual: return L10n.t("is")
        case .contains: return L10n.t("contains")
        case .beginsWith: return L10n.t("begins with")
        case .endsWith: return L10n.t("ends with")
        case .isAnyOf: return L10n.t("is any of")
        case .matchesRegex: return L10n.t("matches regex")
        case .largerThan: return L10n.t("is larger than")
        case .smallerThan: return L10n.t("is smaller than")
        }
    }

    static func priorityLabel(_ priority: FilePriority) -> String {
        switch priority {
        case .high: return L10n.t("High priority")
        case .low: return L10n.t("Low priority")
        default: return L10n.t("Normal priority")
        }
    }

    /// A rule is worth saving once it has a name, a condition with a value, and something to do.
    static func canSave(_ rule: AutoSortRule) -> Bool {
        !rule.name.trimmingCharacters(in: .whitespaces).isEmpty
            && rule.conditions.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            && !actions(rule).isEmpty
    }
}

private struct RuleRow: View {
    let rule: AutoSortRule
    let matches: Int
    let isFirst: Bool
    let isLast: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(L10n.t("Enable rule %@", rule.name))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).scaledFont(size: Theme.TextSize.body, weight: .semibold)
                Text(RulesPreview.summary(rule))
                    .scaledFont(size: Theme.TextSize.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(L10n.t("%d in history", matches))
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
            rowButtons
        }
        .padding(.vertical, 6)
        .opacity(rule.enabled ? 1 : 0.6)
    }

    private var rowButtons: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.up", help: L10n.t("Move up"), size: 10) { onMove(-1) }
                .disabled(isFirst)
            IconButton(symbol: "chevron.down", help: L10n.t("Move down"), size: 10) { onMove(1) }
                .disabled(isLast)
            IconButton(symbol: "pencil", help: L10n.t("Edit rule"), size: 11, action: onEdit)
            IconButton(symbol: "trash", help: L10n.t("Delete rule"), size: 11, action: onDelete)
        }
    }
}
