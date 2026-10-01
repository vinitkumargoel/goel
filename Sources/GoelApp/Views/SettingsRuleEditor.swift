import SwiftUI
import GoelCore

/// Add or edit one rule: conditions on top, what to do below, and a live count of how many
/// past downloads it would have caught.
struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: AutoSortRule
    let history: [AutoSortCandidate]
    let onSave: (AutoSortRule) -> Void

    init(rule: AutoSortRule, history: [AutoSortCandidate], onSave: @escaping (AutoSortRule) -> Void) {
        _rule = State(initialValue: rule)
        self.history = history
        self.onSave = onSave
    }

    static func blankRule() -> AutoSortRule {
        AutoSortRule(name: "", conditions: [.init(field: .fileExtension, op: .isAnyOf, value: "")])
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(systemImage: "line.3.horizontal.decrease.circle", title: L10n.t("Download rule"))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(L10n.t("Rule name"), text: $rule.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.t("Rule name"))
                    RuleConditionsEditor(rule: $rule)
                    RuleActionsEditor(rule: $rule)
                    previewLine
                }
                .padding(18)
            }
            .frame(maxHeight: 460)
            Divider()
            footer
        }
        .frame(width: 560)
    }

    private var previewLine: some View {
        let count = AutoSortRules.matchCount(of: rule, in: history)
        return Label(L10n.t("Would match %1$d of your last %2$d downloads", count, history.count),
                     systemImage: "clock.arrow.circlepath")
            .scaledFont(size: Theme.TextSize.meta)
            .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("Save Rule")) {
                onSave(rule)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!RulesPreview.canSave(rule))
            .help(RulesPreview.canSave(rule) ? "" : L10n.t("Give the rule a name, a condition and at least one action."))
        }
        .padding(14)
    }
}

private struct RuleConditionsEditor: View {
    @Binding var rule: AutoSortRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.t("When a new download matches"))
                    .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                Picker("", selection: $rule.match) {
                    Text(L10n.t("all")).tag(AutoSortRule.Match.all)
                    Text(L10n.t("any")).tag(AutoSortRule.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L10n.t("Match all or any conditions"))
                Text(L10n.t("of these:")).scaledFont(size: Theme.TextSize.body, weight: .semibold)
            }
            ForEach(rule.conditions.indices, id: \.self) { index in
                RuleConditionRow(condition: $rule.conditions[index],
                                 canRemove: rule.conditions.count > 1) {
                    rule.conditions.remove(at: index)
                }
            }
            Button(L10n.t("Add Condition")) {
                rule.conditions.append(.init(field: .fileName, op: .contains, value: ""))
            }
            .controlSize(.small)
        }
    }
}

private struct RuleConditionRow: View {
    @Binding var condition: AutoSortRule.Condition
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: fieldBinding) {
                ForEach(AutoSortRule.Field.allCases) { Text(RulesPreview.fieldLabel($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel(L10n.t("Field"))
            Picker("", selection: $condition.op) {
                ForEach(AutoSortRule.Operator.available(for: condition.field)) {
                    Text(RulesPreview.operatorLabel($0)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel(L10n.t("Comparison"))
            TextField(placeholder, text: $condition.value)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Value"))
            IconButton(symbol: "minus.circle", help: L10n.t("Remove condition"), size: 11, action: onRemove)
                .disabled(!canRemove)
        }
    }

    /// Switching between text and size resets the operator, which the other kind doesn't offer.
    private var fieldBinding: Binding<AutoSortRule.Field> {
        Binding(get: { condition.field }, set: { field in
            condition.field = field
            let allowed = AutoSortRule.Operator.available(for: field)
            if !allowed.contains(condition.op), let first = allowed.first { condition.op = first }
        })
    }

    private var placeholder: String {
        switch (condition.field, condition.op) {
        case (.size, _): return L10n.t("e.g. 1 GB")
        case (.fileExtension, .isAnyOf): return L10n.t("e.g. dmg, pkg, zip")
        case (.domain, _): return L10n.t("e.g. github.com")
        case (_, .matchesRegex): return L10n.t("Regular expression")
        default: return L10n.t("Text")
        }
    }
}

private struct RuleActionsEditor: View {
    @Binding var rule: AutoSortRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Then"))
                .scaledFont(size: Theme.TextSize.body, weight: .semibold)
            LabeledContent(L10n.t("Save to")) { folderControl }
            LabeledContent(L10n.t("Tag")) {
                TextField(L10n.t("None"), text: optionalText(\.tag)).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            LabeledContent(L10n.t("Speed cap (KB/s)")) {
                TextField(L10n.t("No cap"), text: speedText).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            LabeledContent(L10n.t("Priority")) {
                Picker("", selection: priorityBinding) {
                    Text(L10n.t("High")).tag(FilePriority.high)
                    Text(L10n.t("Normal")).tag(FilePriority.normal)
                    Text(L10n.t("Low")).tag(FilePriority.low)
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle(L10n.t("Start paused"), isOn: $rule.startPaused)
            LabeledContent(L10n.t("When done")) { WhenDonePicker(whenDone: whenDoneBinding) }
            if rule.whenDone?.kind == .runScript {
                Label(L10n.t("This script runs unattended for every matching download, including ones added from your browser or the web portal."),
                      systemImage: "exclamationmark.shield")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scaledFont(size: Theme.TextSize.body)
    }

    private var folderControl: some View {
        HStack(spacing: 6) {
            Text(rule.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L10n.t("Default folder rule"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L10n.t("Choose…")) {
                if let url = FilePicker.chooseDirectory() { rule.folder = url.path }
            }
            if rule.folder != nil {
                IconButton(symbol: "xmark.circle", help: L10n.t("Use the default folder rule"), size: 11) {
                    rule.folder = nil
                }
            }
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<AutoSortRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: keyPath] ?? "" }, set: { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            rule[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
        })
    }

    private var speedText: Binding<String> {
        Binding(get: { rule.speedLimitBytesPerSec.map { String($0 / 1_000) } ?? "" }, set: { text in
            let kilobytes = Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0
            rule.speedLimitBytesPerSec = kilobytes > 0 ? kilobytes * 1_000 : nil
        })
    }

    private var priorityBinding: Binding<FilePriority> {
        Binding(get: { rule.priority ?? .normal }, set: { rule.priority = $0 == .normal ? nil : $0 })
    }

    private var whenDoneBinding: Binding<WhenDone> {
        Binding(get: { rule.whenDone ?? .nothing }, set: { rule.whenDone = $0.isActionable ? $0 : nil })
    }
}
