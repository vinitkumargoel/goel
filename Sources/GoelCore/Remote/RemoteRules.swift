import Foundation

/// `GET /api/rules`: the auto-sort rules, in the order they are checked. The same list the desktop
/// app edits, so a change on either side shows on the other.
///
/// Three when-done kinds are never writable here: `runScript` and `openWith` name an executable or app
/// on the host, and `open` launches the downloaded file itself (a `.command` or `.app` fetched by a
/// remote Add would run), so setting one from a browser would be remote code execution by another name. A rule
/// that already has one keeps it (`whenDone.locked`) and says so, but the portal can neither set nor
/// read the path.
public struct RemoteRule: Sendable, Codable, Equatable {
    public struct Condition: Sendable, Codable, Equatable {
        public var field: String
        public var op: String
        public var value: String
    }

    public struct WhenDone: Sendable, Codable, Equatable {
        /// `nothing`, `reveal`, `moveTo`; reads may also show `open`, `openWith` and `runScript`.
        public var kind: String
        /// The folder for `moveTo`.
        public var target: String?
        /// Reads only: the kind cannot be set from the portal, and an update that omits `whenDone` keeps it.
        public var locked: Bool?
    }

    public var id: String?
    public var name: String
    public var enabled: Bool
    /// `all` or `any`.
    public var match: String
    public var conditions: [Condition]
    public var folder: String?
    public var tag: String?
    public var speedLimitBytesPerSec: Int64?
    /// `high`, `normal` or `low`; nil is normal.
    public var priority: String?
    public var startPaused: Bool
    /// Omitted on a write: keep what the rule has (nothing for a new rule).
    public var whenDone: WhenDone?
}

public struct RemoteRulesState: Sendable, Codable, Equatable {
    public var rules: [RemoteRule]
}

/// `POST /api/rules`: the whole ordered list. One list replaces the old one, which makes add, edit,
/// enable, reorder and delete a single atomic write; a rule is matched to its stored self by `id`.
public struct RemoteRulesUpdate: Sendable, Equatable, Decodable {
    public var rules: [RemoteRule]

    static let maxRules = 100
    static let maxName = 120
    static let maxConditions = 10
    static let maxValue = 512
    static let maxPath = 1024
    static let maxTag = 64
    static let priorities: [String: FilePriority] = ["high": .high, "normal": .normal, "low": .low]
    static let writableWhenDone: Set<String> = ["nothing", "reveal", "moveTo"]

    /// Shape checks; folders are vetted by the router against the backend. Refuses rather than clamps.
    func refusal() -> String? {
        if rules.count > Self.maxRules { return "At most \(Self.maxRules) rules." }
        var seen = Set<UUID>()
        for rule in rules {
            if let raw = rule.id {
                guard let id = UUID(uuidString: raw), seen.insert(id).inserted else {
                    return "Each rule needs a unique id."
                }
            }
            if let problem = Self.refusal(for: rule) { return problem }
        }
        return nil
    }

    private static func plain(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func refusal(for rule: RemoteRule) -> String? {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > maxName || !plain(name) {
            return "A rule name is 1–\(maxName) characters, with no control characters."
        }
        if AutoSortRule.Match(rawValue: rule.match) == nil { return "Match must be all or any." }
        if rule.conditions.isEmpty || rule.conditions.count > maxConditions {
            return "A rule needs 1–\(maxConditions) conditions."
        }
        for condition in rule.conditions {
            if let problem = refusal(for: condition) { return problem }
        }
        if let tag = rule.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty,
           tag.count > maxTag || !plain(tag) {
            return "A tag is at most \(maxTag) characters, with no control characters."
        }
        if let cap = rule.speedLimitBytesPerSec, !(0...RemoteRouter.maxSpeedLimit).contains(cap) {
            return "The speed cap must be a whole number of bytes per second, 0 for none."
        }
        if let priority = rule.priority, priorities[priority] == nil { return "Priority must be high, normal or low." }
        if let folder = rule.folder, !folder.isEmpty, let problem = pathRefusal(folder) { return problem }
        if let done = rule.whenDone {
            guard writableWhenDone.contains(done.kind) else {
                return "When done must be nothing, reveal or moveTo."
            }
            if done.kind == "moveTo" {
                guard let target = done.target, !target.isEmpty else { return "Move to needs a folder." }
                if let problem = pathRefusal(target) { return problem }
            }
        }
        return nil
    }

    /// As the desktop editor: a rule must do something. Checked on the resolved list, where a kept
    /// `whenDone` (an Open With the portal cannot set) counts as an action.
    static func actionRefusal(_ resolved: [AutoSortRule]) -> String? {
        resolved.allSatisfy { rule in
            (rule.folder ?? "").isEmpty == false || (rule.tag ?? "").isEmpty == false
                || (rule.speedLimitBytesPerSec ?? 0) > 0 || rule.priority != nil || rule.startPaused
                || rule.whenDone?.isActionable == true
        } ? nil : "A rule needs at least one action."
    }

    private static func refusal(for c: RemoteRule.Condition) -> String? {
        guard let field = AutoSortRule.Field(rawValue: c.field),
              let op = AutoSortRule.Operator(rawValue: c.op),
              AutoSortRule.Operator.available(for: field).contains(op)
        else { return "That condition's field and comparison do not go together." }
        let value = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.count > maxValue || !plain(value) {
            return "A condition value is 1–\(maxValue) characters, with no control characters."
        }
        if op == .matchesRegex {
            if value.count > RuleRegex.maxPatternLength || RuleRegex.compiled(value) == nil {
                return "That regular expression is not valid."
            }
        }
        if field == .size, AutoSortRule.Condition.parseBytes(value) == nil {
            return "A size looks like 500 MB or 1.5 GB."
        }
        return nil
    }

    static func pathRefusal(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !trimmed.hasPrefix("/") { return "A rule's folder must be an absolute path." }
        if trimmed.utf8.count > maxPath || trimmed.contains("\0") { return "That folder path is not valid." }
        return nil
    }

    /// The folders a rule asks for that its stored self did not already have: only new ones need vetting,
    /// so enabling or reordering a rule the desktop app set up is never refused for its old folder.
    func foldersToVet(against current: [AutoSortRule]) -> [String] {
        var out: [String] = []
        for rule in rules {
            let old = rule.id.flatMap(UUID.init(uuidString:)).flatMap { id in current.first { $0.id == id } }
            if let f = rule.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty, f != old?.folder {
                out.append(f)
            }
            if rule.whenDone?.kind == "moveTo", let t = rule.whenDone?.target?
                .trimmingCharacters(in: .whitespacesAndNewlines), t != old?.whenDone?.target {
                out.append(t)
            }
        }
        return out
    }

    /// The new list. A stored rule's `whenDone` survives an update that leaves it out.
    func resolved(against current: [AutoSortRule]) -> [AutoSortRule] {
        rules.map { rule in
            let id = rule.id.flatMap(UUID.init(uuidString:)) ?? UUID()
            let old = current.first { $0.id == id }
            func clean(_ s: String?) -> String? {
                let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (t ?? "").isEmpty ? nil : t
            }
            var whenDone = old?.whenDone
            if let done = rule.whenDone, let kind = WhenDone.Kind(rawValue: done.kind) {
                whenDone = kind == .nothing ? nil : WhenDone(kind, target: clean(done.target))
            }
            let cap = rule.speedLimitBytesPerSec.flatMap { $0 > 0 ? $0 : nil }
            return AutoSortRule(
                id: id, name: rule.name.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: rule.enabled, match: AutoSortRule.Match(rawValue: rule.match) ?? .all,
                conditions: rule.conditions.compactMap { c in
                    guard let f = AutoSortRule.Field(rawValue: c.field),
                          let o = AutoSortRule.Operator(rawValue: c.op) else { return nil }
                    return .init(field: f, op: o, value: c.value.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                folder: clean(rule.folder), tag: clean(rule.tag), speedLimitBytesPerSec: cap,
                priority: rule.priority.flatMap { Self.priorities[$0] }.flatMap { $0 == .normal ? nil : $0 },
                startPaused: rule.startPaused, whenDone: whenDone)
        }
    }
}

extension RemoteRulesState {
    init(_ s: AppSettings) {
        self.init(rules: s.autoSortRules.map(RemoteRule.init))
    }
}

extension RemoteRule {
    init(_ r: AutoSortRule) {
        let locked = r.whenDone.map { $0.kind == .open || $0.kind == .openWith || $0.kind == .runScript } ?? false
        self.init(
            id: r.id.uuidString, name: r.name, enabled: r.enabled, match: r.match.rawValue,
            conditions: r.conditions.map { .init(field: $0.field.rawValue, op: $0.op.rawValue, value: $0.value) },
            folder: r.folder, tag: r.tag, speedLimitBytesPerSec: r.speedLimitBytesPerSec,
            priority: r.priority.flatMap { p in RemoteRulesUpdate.priorities.first { $0.value == p }?.key },
            startPaused: r.startPaused,
            whenDone: r.whenDone.map {
                WhenDone(kind: $0.kind.rawValue, target: $0.kind == .moveTo ? $0.target : nil,
                         locked: locked ? true : nil)
            })
    }
}
