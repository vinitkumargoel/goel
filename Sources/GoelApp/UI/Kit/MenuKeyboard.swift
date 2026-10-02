import SwiftUI
import GoelCore

/// Keyboard rules for a Studio popover menu (``Dropdown``, ``SettingsSelect``,
/// ``DownloadStudioMenu``), as a native pop-up menu has them: ↑ ↓ move the highlight and stop at
/// the ends, Home / End jump there, ↩ or Space picks, Esc closes, typing jumps to the first item
/// whose title starts with what was typed. Indices count only the items that can be picked.
enum MenuKeyboard {
    /// Typed characters within this long of each other build one search ("Me" → "Medium").
    static let typeSelectWindow: TimeInterval = 1

    static func step(from current: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset < 0 ? count - 1 : 0 }
        return min(count - 1, max(0, current + offset))
    }

    /// The first title (from the highlighted one on, wrapping) that starts with `typed`, ignoring
    /// case and accents. A repeated single letter cycles through the items that start with it.
    static func match(_ typed: String, in titles: [String], from current: Int?) -> Int? {
        guard !typed.isEmpty, !titles.isEmpty else { return nil }
        let needle = typed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let repeated = needle.count > 1 && Set(needle).count == 1
        let search = repeated ? String(needle.prefix(1)) : needle
        // A fresh search starts at the highlight; a repeated letter moves past it.
        let start = (current ?? -1) + (repeated || needle.count == 1 ? 1 : 0)
        for offset in 0..<titles.count {
            let index = (max(0, start) + offset) % titles.count
            let title = titles[index].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if title.hasPrefix(search) { return index }
        }
        return nil
    }
}

/// Drives a menu's highlight from the keyboard; the menu draws `highlighted` and calls back.
private struct MenuKeyboardModifier: ViewModifier {
    let titles: [String]
    let initial: Int?
    @Binding var highlighted: Int?
    let onActivate: (Int) -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast

    // The key target sits behind the menu, not around it: a focusable ancestor would make every
    // row read `isFocused` and draw its focus ring.
    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress { handle($0) }
                    .accessibilityHidden(true)
            }
            .onAppear {
                highlighted = initial
                focused = true
            }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow, .downArrow:
            highlighted = MenuKeyboard.step(from: highlighted, by: press.key == .downArrow ? 1 : -1, count: titles.count)
        case .home, .end:
            highlighted = MenuKeyboard.step(from: nil, by: press.key == .end ? -1 : 1, count: titles.count)
        case .return, .space:
            guard let highlighted else { return .ignored }
            onActivate(highlighted)
        case .escape:
            onClose()
        default:
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
            else { return .ignored }
            let now = Date()
            typed = now.timeIntervalSince(typedAt) < MenuKeyboard.typeSelectWindow ? typed + press.characters : press.characters
            typedAt = now
            if let hit = MenuKeyboard.match(typed, in: titles, from: highlighted) { highlighted = hit }
        }
        return .handled
    }
}

extension View {
    /// Keyboard navigation for a popover menu whose pickable items are `titles`, in order. It
    /// takes focus when the menu appears and highlights `initial` (the current choice); with
    /// none, the first ↓ or ↑ lands on the first or last item.
    func studioMenuKeyboard(titles: [String], initial: Int?, highlighted: Binding<Int?>,
                            onActivate: @escaping (Int) -> Void, onClose: @escaping () -> Void) -> some View {
        modifier(MenuKeyboardModifier(titles: titles, initial: initial, highlighted: highlighted,
                                      onActivate: onActivate, onClose: onClose))
    }
}
