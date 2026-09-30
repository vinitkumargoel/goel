import Foundation
import GoelCore

/// Sidebar tag rows act on every download carrying the tag. Tags compare case-insensitively
/// (``ListPresentation/tagCounts``), and a legacy label counts as a tag, so both are rewritten.
@MainActor
extension AppViewModel {

    /// The rows a tag operation touches, and each one's tags after `transform`.
    static func retagged(_ tasks: [DownloadTask], tag: String,
                         replacement: String?) -> [(id: DownloadTask.ID, tags: [String], label: String??)] {
        let key = tag.lowercased()
        return tasks.compactMap { task in
            guard task.allTags.contains(where: { $0.lowercased() == key }) else { return nil }
            var seen = Set<String>()
            let tags = (task.tags ?? []).compactMap { existing -> String? in
                existing.lowercased() == key ? replacement : existing
            }.filter { seen.insert($0.lowercased()).inserted }
            // .some(nil) clears the label; nil leaves it alone.
            let label: String?? = task.label?.lowercased() == key ? .some(replacement) : nil
            return (task.id, tags, label)
        }
    }

    func renameTag(_ tag: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != tag else { return }
        apply(Self.retagged(tasks, tag: tag, replacement: name))
        TagColors.update { TagColors.renamed($0, from: tag, to: name) }
        if case .tag(let current) = filter, current.lowercased() == tag.lowercased() { filter = .tag(name) }
        toastSuccess(L10n.t("Renamed tag “%1$@” to “%2$@”", tag, name))
    }

    func removeTagFromAll(_ tag: String) {
        let changes = Self.retagged(tasks, tag: tag, replacement: nil)
        apply(changes)
        TagColors.update { TagColors.removed($0, tag: tag) }
        if case .tag(let current) = filter, current.lowercased() == tag.lowercased() { filter = .all }
        toastSuccess(changes.count == 1 ? L10n.t("Removed tag “%@” from 1 download", tag)
                                        : L10n.t("Removed tag “%1$@” from %2$d downloads", tag, changes.count))
    }

    func promptForTagRename(_ tag: String) {
        guard let value = Self.promptText(title: L10n.t("Rename tag “%@”", tag),
                                          message: L10n.t("Every download with this tag gets the new name."),
                                          confirm: L10n.t("Rename"), initial: tag) else { return }
        renameTag(tag, to: value)
    }

    private func apply(_ changes: [(id: DownloadTask.ID, tags: [String], label: String??)]) {
        let manager = self.manager
        Task {
            for change in changes {
                await manager.setTags(change.tags, task: change.id)
                if let label = change.label { await manager.setLabel(label, task: change.id) }
            }
        }
    }
}

/// A tag's colour: the user's pick when there is one, else a stable slot from its name.
enum TagColors {
    static let storageKey = "sidebar.tagColors"

    static func decode(_ raw: String) -> [String: Int] {
        (try? JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))) ?? [:]
    }

    static func encode(_ map: [String: Int]) -> String {
        (try? String(decoding: JSONEncoder().encode(map), as: UTF8.self)) ?? ""
    }

    static func setting(_ map: [String: Int], tag: String, slot: Int) -> [String: Int] {
        var out = map
        out[tag.lowercased()] = slot
        return out
    }

    /// A renamed tag keeps its colour; the new name's own pick, if any, gives way to it.
    static func renamed(_ map: [String: Int], from old: String, to new: String) -> [String: Int] {
        guard let slot = map[old.lowercased()] else { return map }
        var out = map
        out[old.lowercased()] = nil
        out[new.lowercased()] = slot
        return out
    }

    static func removed(_ map: [String: Int], tag: String) -> [String: Int] {
        var out = map
        out[tag.lowercased()] = nil
        return out
    }

    /// Rewrites the stored map; the sidebar's `@AppStorage` sees the change.
    static func update(_ transform: ([String: Int]) -> [String: Int],
                       defaults: UserDefaults = .standard) {
        let current = decode(defaults.string(forKey: storageKey) ?? "")
        let next = transform(current)
        guard next != current else { return }
        defaults.set(encode(next), forKey: storageKey)
    }

    static func slot(for tag: String, overrides: [String: Int], slots: Int) -> Int {
        if let chosen = overrides[tag.lowercased()], (0..<slots).contains(chosen) { return chosen }
        return ListPresentation.tagColorSlot(tag, slots: slots)
    }
}
