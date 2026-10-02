import SwiftUI
import AppKit
import GoelCore

/// Mouse selection and the keyboard: arrows, ⌘↓/⌘↑, Return, Space, Delete, Esc, ⌘A/C/X/V/D/I
/// and type-to-select, as Finder has them.
extension SFTPBrowserView {

    func handleClick(_ entry: SFTPEntry) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        } else if mods.contains(.shift), let anchor = cursor,
                  let a = visibleEntries.firstIndex(where: { $0.id == anchor }),
                  let b = visibleEntries.firstIndex(where: { $0.id == entry.id }) {
            let range = a <= b ? a...b : b...a
            selection = Set(visibleEntries[range].map(\.id))
        } else {
            selection = [entry.id]
        }
        cursor = entry.id
        listFocused = true
    }

    func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let entries = visibleEntries
        guard !entries.isEmpty else { return .ignored }
        let current = cursor.flatMap { id in entries.firstIndex { $0.id == id } }
        switch press.key {
        case .downArrow, .upArrow:
            if press.modifiers.contains(.command) {
                if press.key == .downArrow {
                    if let c = current { primaryAction(entries[c]) }
                } else {
                    Task { await model.goUp() }
                }
                return .handled
            }
            let next = press.key == .downArrow
                ? min(entries.count - 1, (current ?? -1) + 1)
                : max(0, (current ?? 0) - 1)
            let id = entries[next].id
            cursor = id
            if press.modifiers.contains(.shift) { selection.insert(id) } else { selection = [id] }
            proxy.scrollTo(id, anchor: .center)
            return .handled
        case .return:
            if let c = current { primaryAction(entries[c]) }
            return .handled
        case .space:
            if let c = current, !entries[c].isDirectory { quickLook(entries[c]) }
            return .handled
        case .delete, .deleteForward:
            let targets = entries.filter { selection.contains($0.id) }
            if !targets.isEmpty { deleteTargets(targets) }
            return .handled
        case .escape:
            if info.entry != nil && selection.isEmpty { closeInfo() } else { selection.removeAll() }
            return .handled
        default:
            guard press.modifiers.contains(.command) else {
                guard press.modifiers.subtracting(.shift).isEmpty,
                      let character = press.characters.first,
                      character.isLetter || character.isNumber
                        || character == "." || character == "-" || character == "_"
                else { return .ignored }
                return typeSelect(character, entries: entries, proxy: proxy)
            }
            return commandKey(press, entries: entries)
        }
    }

    private func commandKey(_ press: KeyPress, entries: [SFTPEntry]) -> KeyPress.Result {
        switch press.key {
        case KeyEquivalent("a"):
            selection = Set(entries.map(\.id)); return .handled
        case KeyEquivalent("c"):
            copySelection(.copy); return .handled
        case KeyEquivalent("x"):
            copySelection(.cut); return .handled
        case KeyEquivalent("v"):
            vm.pasteSFTPClipboard(into: model.connection, directory: model.path)
            return .handled
        case KeyEquivalent("d"):
            duplicateSelection(); return .handled
        case KeyEquivalent("i"):
            if let target = clipboardTargets().first { showInfo(target) }
            return .handled
        default:
            return .ignored
        }
    }

    private func typeSelect(_ character: Character, entries: [SFTPEntry],
                            proxy: ScrollViewProxy) -> KeyPress.Result {
        let now = Date()
        let continuing = now.timeIntervalSince(typeSelectAt) < Self.typeSelectWindow
        typeSelectAt = now

        let repeated = continuing && typeSelectBuffer == String(character)
        typeSelectBuffer = continuing && !repeated ? typeSelectBuffer + String(character)
                                                  : String(character)

        let startIndex: Int
        if repeated, let c = cursor.flatMap({ id in entries.firstIndex { $0.id == id } }) {
            startIndex = c + 1
        } else {
            startIndex = 0
        }
        let prefix = typeSelectBuffer.lowercased()
        let order = (0..<entries.count).map { (startIndex + $0) % entries.count }
        guard let hit = order.first(where: { entries[$0].name.lowercased().hasPrefix(prefix) })
        else { return .handled }

        let id = entries[hit].id
        cursor = id
        selection = [id]
        proxy.scrollTo(id, anchor: .center)
        return .handled
    }
}
