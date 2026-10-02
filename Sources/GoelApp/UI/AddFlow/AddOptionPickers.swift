import SwiftUI
import AppKit
import GoelCore

/// "Save to" with the usual folders plus the last few the user picked. `nil` means the default rule.
struct SaveFolderPicker: View {
    @Binding var folder: String?
    let automaticLabel: String

    @State private var selection = Self.automatic
    @State private var recent: [String] = RecentFolders.load()

    private static let automatic = "automatic"
    private static let choose = "__choose__"

    private var downloadsPath: String { ("~/Downloads" as NSString).expandingTildeInPath }
    private var moviesPath: String { ("~/Movies" as NSString).expandingTildeInPath }

    var body: some View {
        Dropdown(selection: $selection, items: items, accessibilityName: L10n.t("Save to")) { picked in
            handle(picked)
        }
        .onAppear { selection = folder ?? Self.automatic }
    }

    private var items: [Dropdown<String>.Item] {
        var result: [Dropdown<String>.Item] = [
            .option(Self.automatic, automaticLabel), .separator,
            .option(downloadsPath, "~/Downloads"), .option(moviesPath, "~/Movies"),
        ]
        let extra = Self.extraFolders(recent: recent, current: folder,
                                      fixed: [downloadsPath, moviesPath])
        if !extra.isEmpty {
            result.append(.separator)
            result += extra.map { .option($0, ($0 as NSString).abbreviatingWithTildeInPath) }
        }
        result += [.separator, .option(Self.choose, L10n.t("Choose folder…"))]
        return result
    }

    /// The chosen folder and the recent ones, minus those already listed above them.
    static func extraFolders(recent: [String], current: String?, fixed: [String]) -> [String] {
        var seen = Set(fixed)
        return ([current].compactMap { $0 } + recent).filter { seen.insert($0).inserted }
    }

    private func handle(_ picked: String) {
        switch picked {
        case Self.automatic:
            folder = nil
        case Self.choose:
            if let url = FilePicker.chooseDirectory() {
                folder = url.path
                selection = url.path
            } else {
                selection = folder ?? Self.automatic
            }
        default:
            folder = picked
        }
    }
}

/// "When done": nothing, open, reveal, or one that needs a target picked right away.
/// Also used by Settings › Rules and the row's When Done menu (labels only).
struct WhenDonePicker: View {
    @Binding var whenDone: WhenDone
    var width: CGFloat? = 170

    @State private var selection = WhenDone.Kind.nothing.rawValue

    var body: some View {
        Dropdown(selection: $selection, items: items, width: width,
                 accessibilityName: L10n.t("When done")) { picked in
            handle(picked)
        }
        .onAppear { selection = whenDone.kind.rawValue }
        .help(Self.summary(whenDone))
    }

    private var items: [Dropdown<String>.Item] {
        WhenDone.Kind.allCases.map { .option($0.rawValue, Self.label($0)) }
    }

    static func label(_ kind: WhenDone.Kind) -> String {
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
    static func summary(_ whenDone: WhenDone) -> String {
        guard let target = whenDone.target, !target.isEmpty else { return label(whenDone.kind) }
        return L10n.t("%1$@ %2$@", label(whenDone.kind), (target as NSString).abbreviatingWithTildeInPath)
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

/// Priority as the add flow offers it: High · Normal · Low, a full-width segmented control.
struct PriorityPicker: View {
    @Binding var priority: FilePriority

    var body: some View {
        StudioSegmentedControl(selection: $priority, segments: [
            StudioSegment(FilePriority.high, title: L10n.t("High")),
            StudioSegment(FilePriority.normal, title: L10n.t("Normal")),
            StudioSegment(FilePriority.low, title: L10n.t("Low")),
        ], fullWidth: true, accessibilityLabel: L10n.t("Priority"))
    }
}

/// When the download starts: now, or one of the scheduled presets.
struct StartPicker: View {
    @Binding var selection: String
    var width: CGFloat?

    static let now = "now"

    var body: some View {
        Dropdown(selection: $selection, items: Self.options, width: width,
                 accessibilityName: L10n.t("Start"))
    }

    static var options: [Dropdown<String>.Item] {
        [.option(now, L10n.t("Now"))] + ScheduledStartOption.presets.map { .option($0.id, $0.label) }
    }

    /// The date the selection stands for; nil starts right away.
    static func date(for selection: String) -> Date? {
        ScheduledStartOption.presets.first { $0.id == selection }?.date()
    }
}

/// A labelled column in the add forms: the caption above its control.
struct AddOptionColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            AddFieldLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
