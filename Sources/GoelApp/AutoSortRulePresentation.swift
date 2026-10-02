import Foundation
import GoelCore

/// What the Rules pane and editor show about auto-sort rules: the one-line summary and the
/// field/operator/When-done labels, which rules can be saved, reordering, and past downloads turned
/// into candidates for the live match preview. Pure, kept out of the views so it can be tested.
enum AutoSortRulePresentation {

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
        if let whenDone = rule.whenDone, whenDone.isActionable { parts.append(whenDoneLabel(whenDone.kind)) }
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

    /// The same labels the Add sheet's "When done" menu uses.
    static func whenDoneLabel(_ kind: WhenDone.Kind) -> String {
        switch kind {
        case .nothing: return L10n.t("Do nothing")
        case .open: return L10n.t("Open")
        case .reveal: return L10n.t("Show in Finder")
        case .openWith: return L10n.t("Open With…")
        case .moveTo: return L10n.t("Move to…")
        case .runScript: return L10n.t("Run script…")
        }
    }

    /// The tooltip names the app, folder or script, which the menu title can't fit.
    static func whenDoneSummary(_ whenDone: WhenDone) -> String {
        guard let target = whenDone.target, !target.isEmpty else { return whenDoneLabel(whenDone.kind) }
        return L10n.t("%1$@ %2$@", whenDoneLabel(whenDone.kind), (target as NSString).abbreviatingWithTildeInPath)
    }

    /// A rule is worth saving once it has a name, a condition with a value, and something to do.
    static func canSave(_ rule: AutoSortRule) -> Bool {
        !rule.name.trimmingCharacters(in: .whitespaces).isEmpty
            && rule.conditions.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            && !actions(rule).isEmpty
    }
}
