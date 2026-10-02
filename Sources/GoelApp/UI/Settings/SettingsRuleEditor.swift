import SwiftUI
import GoelCore

/// Add or edit one rule. It reads as a sentence — when these conditions match, do this — with a
/// live count of how many past downloads it would have caught.
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
        StudioSheet(title: L10n.t("Download rule"),
                    subtitle: L10n.t("Sort new downloads by name, type, site or size."),
                    symbol: "line.3.horizontal.decrease.circle", width: 580) {
            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    VStack(alignment: .leading, spacing: 5) {
                        RuleFieldLabel(L10n.t("Rule name"))
                        SettingsTextField(text: $rule.name, width: nil, placeholder: L10n.t("Rule name"),
                                          accessibilityName: L10n.t("Rule name"), size: .regular)
                    }
                    RuleConditionsEditor(rule: $rule)
                    RuleActionsEditor(rule: $rule)
                }
                .padding(.vertical, Studio.Space.hair)
                .padding(.trailing, Studio.Space.xxs)
            }
            .frame(maxHeight: 540)
            .fixedSize(horizontal: false, vertical: true)
            // Outside the scroll view: the live count stays in sight while the rule is edited.
            previewLine
        } footer: {
            StudioSheetFooter(onCancel: { dismiss() },
                              primaryTitle: L10n.t("Save Rule"),
                              primaryEnabled: AutoSortRulePresentation.canSave(rule)) {
                onSave(rule)
                dismiss()
            } leading: {
                if !AutoSortRulePresentation.canSave(rule) {
                    Text(L10n.t("Give the rule a name, a condition and at least one action."))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(AutoSortRulePresentation.canSave(rule)
                  ? "" : L10n.t("Give the rule a name, a condition and at least one action."))
        }
    }

    private var previewLine: some View {
        let count = AutoSortRules.matchCount(of: rule, in: history)
        return StudioNote(tone: count > 0 ? .accent : .neutral, symbol: "clock.arrow.circlepath",
                          message: L10n.t("Would match %1$d of your last %2$d downloads", count, history.count))
    }
}

private struct RuleFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .studioFont(.small.weight(650))
            .foregroundStyle(Studio.Palette.ink2)
    }
}

private struct RuleConditionsEditor: View {
    @Binding var rule: AutoSortRule

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack(spacing: Studio.Space.s) {
                Text(L10n.t("When a new download matches"))
                    .studioFont(.title3.size(14))
                    .foregroundStyle(Studio.Palette.ink)
                StudioSegmentedControl(selection: $rule.match, segments: [
                    StudioSegment(AutoSortRule.Match.all, title: L10n.t("all")),
                    StudioSegment(AutoSortRule.Match.any, title: L10n.t("any")),
                ], size: .small, accessibilityLabel: L10n.t("Match all or any conditions"))
                Text(L10n.t("of these:"))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
            }
            ForEach(rule.conditions.indices, id: \.self) { index in
                RuleConditionRow(condition: $rule.conditions[index],
                                 canRemove: rule.conditions.count > 1) {
                    rule.conditions.remove(at: index)
                }
            }
            Button(L10n.t("Add Condition"), systemImage: "plus") {
                rule.conditions.append(.init(field: .fileName, op: .contains, value: ""))
            }
            .buttonStyle(.studio(.ghost, size: .small))
        }
    }
}

private struct RuleConditionRow: View {
    @Binding var condition: AutoSortRule.Condition
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            SettingsSelect(selection: fieldBinding,
                           options: AutoSortRule.Field.allCases.map {
                               SettingsOption($0, AutoSortRulePresentation.fieldLabel($0))
                           },
                           width: 112, accessibilityName: L10n.t("Field"))
            SettingsSelect(selection: $condition.op,
                           options: AutoSortRule.Operator.available(for: condition.field)
                               .map { SettingsOption($0, AutoSortRulePresentation.operatorLabel($0)) },
                           width: 132, accessibilityName: L10n.t("Comparison"))
            SettingsTextField(text: $condition.value, width: nil, placeholder: placeholder,
                              isMonospaced: true, accessibilityName: L10n.t("Value"))
            SettingsRowIconButton(symbol: "minus.circle", label: L10n.t("Remove condition"), action: onRemove)
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
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            Text(L10n.t("Then"))
                .studioFont(.title3.size(14))
                .foregroundStyle(Studio.Palette.ink)
            Grid(alignment: .leading, horizontalSpacing: Studio.Space.sm, verticalSpacing: Studio.Space.sm) {
                GridRow {
                    RuleFieldLabel(L10n.t("Save to"))
                    folderControl
                }
                GridRow {
                    RuleFieldLabel(L10n.t("Tag"))
                    SettingsTextField(text: optionalText(\.tag), width: 200, placeholder: L10n.t("None"),
                                      accessibilityName: L10n.t("Tag"))
                }
                GridRow {
                    RuleFieldLabel(L10n.t("Speed cap (KB/s)"))
                    SettingsTextField(text: speedText, width: 120, placeholder: L10n.t("No cap"),
                                      isMonospaced: true, accessibilityName: L10n.t("Speed cap (KB/s)"))
                }
                GridRow {
                    RuleFieldLabel(L10n.t("Priority"))
                    StudioSegmentedControl(selection: priorityBinding, segments: [
                        StudioSegment(FilePriority.high, title: L10n.t("High")),
                        StudioSegment(FilePriority.normal, title: L10n.t("Normal")),
                        StudioSegment(FilePriority.low, title: L10n.t("Low")),
                    ], size: .small, accessibilityLabel: L10n.t("Priority"))
                }
                GridRow {
                    RuleFieldLabel(L10n.t("Start paused"))
                    Toggle(isOn: $rule.startPaused) { EmptyView() }
                        .toggleStyle(.studioSwitch)
                        .accessibilityLabel(L10n.t("Start paused"))
                }
                GridRow {
                    RuleFieldLabel(L10n.t("When done"))
                    RuleWhenDoneSelect(whenDone: whenDoneBinding)
                }
            }
            if rule.whenDone?.kind == .runScript {
                StudioNote(tone: .warn, symbol: "exclamationmark.shield",
                           message: L10n.t("This script runs unattended for every matching download, including ones "
                                           + "added from your browser or the web portal."))
            }
        }
    }

    private var folderControl: some View {
        HStack(spacing: Studio.Space.xs) {
            HStack(spacing: Studio.Space.xs) {
                Image(systemName: "folder")
                    .studioFont(.ui, size: 12, weight: 650)
                    .foregroundStyle(Studio.Palette.accent)
                    .accessibilityHidden(true)
                Text(rule.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L10n.t("Default folder rule"))
                    .studioFont(rule.folder == nil ? .small : .monoBody)
                    .foregroundStyle(rule.folder == nil ? Studio.Palette.ink3 : Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(height: StudioFieldSize.small.height)
            .modifier(StudioFieldChrome(isFocused: false, radius: StudioFieldSize.small.radius))
            .accessibilityElement(children: .combine)
            Button(L10n.t("Choose…")) {
                if let url = FilePicker.chooseDirectory() { rule.folder = url.path }
            }
            .buttonStyle(.studio(.secondary, size: .small))
            if rule.folder != nil {
                SettingsRowIconButton(symbol: "xmark.circle", label: L10n.t("Use the default folder rule")) {
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

/// "When done": a kind that needs a target (an app, a folder, a script) asks for it right away and
/// falls back to the previous choice when the panel is cancelled.
private struct RuleWhenDoneSelect: View {
    @Binding var whenDone: WhenDone
    @State private var selection = WhenDone.Kind.nothing.rawValue

    var body: some View {
        SettingsSelect(selection: $selection,
                       options: WhenDone.Kind.allCases.map {
                           SettingsOption($0.rawValue, AutoSortRulePresentation.whenDoneLabel($0))
                       },
                       width: 200, accessibilityName: L10n.t("When done")) { picked in
            handle(picked)
        }
        .onAppear { selection = whenDone.kind.rawValue }
        .help(AutoSortRulePresentation.whenDoneSummary(whenDone))
    }

    private func handle(_ raw: String) {
        guard let kind = WhenDone.Kind(rawValue: raw) else { return }
        switch kind {
        case .nothing, .open, .reveal:
            whenDone = WhenDone(kind)
        case .openWith, .moveTo, .runScript:
            if let target = AppViewModel.chooseWhenDoneTarget(for: kind) {
                whenDone = WhenDone(kind, target: target)
            } else {
                selection = whenDone.kind.rawValue
            }
        }
    }
}
