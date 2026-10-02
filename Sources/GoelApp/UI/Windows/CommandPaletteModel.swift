import Foundation
import GoelCore

/// Posts the "toggle the command palette" request the main window listens for (⌘K, the menu).
enum CommandPaletteBus {

    static let toggleNotification = Notification.Name("goel.commandPalette.toggle")

    static func toggle() {
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }
}

/// A settings deep link: the pane to show, and a row to light up once it is shown.
@MainActor
final class SettingsRoute: ObservableObject {

    static let shared = SettingsRoute()

    /// ``SettingsView`` must clear this after switching, or the same pane twice won't navigate.
    @Published var requestedPane: SettingsView.Pane?
    /// A row title to search for once the pane is shown, so the row lights up (palette row results).
    var requestedHighlight: String?

    private init() {}

    func request(_ pane: SettingsView.Pane, highlight: String? = nil) {
        requestedHighlight = highlight
        requestedPane = pane
    }
}

/// One thing the palette can run.
struct PaletteCommand: Identifiable {

    /// What a command acts on. The order here is the order the palette lists the groups in.
    enum Group: Int, CaseIterable, Comparable {
        case selection, task, add, windows, queue, panels, settings, theme, discover

        var title: String {
            switch self {
            case .selection: return L10n.t("Selection")
            case .task: return L10n.t("In your list")
            case .add: return L10n.t("Adding")
            case .windows: return L10n.t("Windows")
            case .queue: return L10n.t("Queue")
            case .panels: return L10n.t("Panels")
            case .settings: return L10n.t("Settings")
            case .theme: return L10n.t("Appearance")
            case .discover: return L10n.t("Where is…")
            }
        }

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let group: Group
    /// Display label only — the real shortcut is registered by the menu command, not here.
    var shortcut: String?
    var keywords: [String] = []
    let run: () -> Void
}

/// Ranking and grouping for the palette's list. Pure, so it can be reasoned about without a view.
enum PaletteRanking {

    /// nil drops the command; higher sorts first.
    static func score(_ command: PaletteCommand, _ needle: String) -> Int? {
        let title = command.title.lowercased()
        if title.hasPrefix(needle) { return 300 }

        let terms = command.keywords.map { $0.lowercased() }
        if terms.contains(where: { $0.hasPrefix(needle) }) { return 250 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 200 }
        if terms.contains(where: { $0.contains(needle) }) { return 150 }
        if title.contains(needle) { return 120 }
        if command.subtitle.lowercased().contains(needle) { return 60 }
        return nil
    }

    /// Matching commands, best first. `sorted(by:)` is unstable, so ties fall back to the
    /// declared position, or rows would swap on every keystroke.
    static func ranked(_ commands: [PaletteCommand], needle: String) -> [PaletteCommand] {
        commands
            .compactMap { command -> (PaletteCommand, Int)? in
                guard let score = score(command, needle) else { return nil }
                return (command, score)
            }
            .enumerated()
            .sorted { a, b in
                a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 > b.element.1
            }
            .map(\.element.0)
    }

    /// Runs of the same group, in the order given: a ranked list keeps its best match on top, and
    /// a group that recurs further down (a weaker match) simply opens a second run.
    static func sections(_ commands: [PaletteCommand]) -> [(group: PaletteCommand.Group, commands: [PaletteCommand])] {
        var result: [(group: PaletteCommand.Group, commands: [PaletteCommand])] = []
        for command in commands {
            if let last = result.last, last.group == command.group {
                result[result.count - 1].commands.append(command)
            } else {
                result.append((command.group, [command]))
            }
        }
        return result
    }

    /// Ranked commands regrouped so each group appears once, groups ordered by their best match.
    static func grouped(_ ranked: [PaletteCommand]) -> [PaletteCommand] {
        var order: [PaletteCommand.Group] = []
        var buckets: [PaletteCommand.Group: [PaletteCommand]] = [:]
        for command in ranked {
            if buckets[command.group] == nil { order.append(command.group) }
            buckets[command.group, default: []].append(command)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }
}
