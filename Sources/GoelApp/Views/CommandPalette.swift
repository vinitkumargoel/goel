import SwiftUI
import AppKit
import GoelCore

enum CommandPaletteBus {

    static let toggleNotification = Notification.Name("goel.commandPalette.toggle")

    static func toggle() {
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }
}

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

struct PaletteCommand: Identifiable {

    enum Group: String {
        case selection = "Selection"
        case task = "In your list"
        case add = "Add"
        case downloads = "Downloads"
        case view = "View"
        case settings = "Settings"
        case discover = "Where is…"
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

struct CommandPalette: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query: String = ""

    /// Index into ``matches``; must be re-clamped or a shrinking list leaves it past the end.
    @State private var highlighted: Int = 0

    @FocusState private var searchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if matches.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass",
                               title: L10n.t("No matching command"),
                               subtitle: L10n.t("Try “rss”, “mirror”, “watch folder”, or “cookies”."),
                               symbolSize: 26)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
            } else {
                resultList
            }
            Divider()
            legend
        }
        .frame(width: 620)
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .scaledFont(size: Theme.TextSize.body, weight: .medium)
                .foregroundStyle(Theme.accent)
                .a11yDecorative()
            TextField(L10n.t("Search actions and settings…"), text: $query)
                .textFieldStyle(.plain)
                .scaledFont(size: Theme.TextSize.sheet)
                .focused($searchFocused)
                .onSubmit { runHighlighted() }
                .onChange(of: query) { _, _ in highlighted = 0 }
                .accessibilityLabel(L10n.t("Search actions and settings"))
                .accessibilityHint(L10n.t("Use the up and down arrow keys to move through results, return to run."))
                .accessibilityValue(matches.indices.contains(highlighted)
                                    ? L10n.t("%1$@ results, %2$@ selected",
                                             String(matches.count), matches[highlighted].title)
                                    : L10n.t("No results"))
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: L10n.t("Clear search"), size: 12) {
                    query = ""
                    searchFocused = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        // Arrow keys must be handled on the field, not the list, or they move the text cursor.
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        PaletteRow(command: command, isHighlighted: index == highlighted) {
                            run(command)
                        }
                        .id(command.id)
                        .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(6)
            }
            .frame(height: 360)
            .onChange(of: highlighted) { _, new in
                guard matches.indices.contains(new) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                    proxy.scrollTo(matches[new].id, anchor: .center)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendKey("↑↓", L10n.t("Navigate"))
            legendKey("↩", L10n.t("Run"))
            legendKey("esc", L10n.t("Close"))
            Spacer()
            Text(L10n.t("%1$@ of %2$@", String(matches.count), String(commands.count)))
                .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .a11yDecorative()
    }

    private func legendKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold, design: .monospaced)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label).scaledFont(size: Theme.TextSize.caption).foregroundStyle(.secondary)
        }
    }

    private func move(by delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        highlighted = (highlighted + delta + matches.count) % matches.count
        return .handled
    }

    private func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    /// Dismiss before running: AppKit won't stack a sheet on a window still showing this one.
    private func run(_ command: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async(execute: command.run)
    }

    private var matches: [PaletteCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }
        // Downloads and single settings rows only join once something is typed: listed up front
        // they would bury the commands.
        return (commands + taskCommands(needle) + settingsRowCommands(needle))
            .compactMap { command -> (PaletteCommand, Int)? in
                guard let score = Self.score(command, needle) else { return nil }
                return (command, score)
            }
            // `sorted(by:)` is unstable: tie-break on declared position or rows swap per keystroke.
            .enumerated()
            .sorted { a, b in
                a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 > b.element.1
            }
            .map(\.element.0)
    }

    private static func score(_ command: PaletteCommand, _ needle: String) -> Int? {
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

    private var commands: [PaletteCommand] {
        selectionCommands + addCommands + downloadCommands + viewCommands + settingsCommands + discoverCommands
    }

    /// Acts on what is selected in the list, named with the count so it is clear what will run.
    private var selectionCommands: [PaletteCommand] {
        let selected = vm.selectedServer == nil ? vm.selectedTasks : []
        guard !selected.isEmpty else { return [] }
        let count = selected.count
        var list: [PaletteCommand] = []
        if selected.contains(where: { $0.status.isActive }) {
            list.append(PaletteCommand(id: "sel.pause", title: L10n.t("Pause Selected (%d)", count),
                                       subtitle: L10n.t("Hold the selected downloads"),
                                       symbol: "pause.fill", group: .selection, shortcut: "⌘P",
                                       keywords: ["pause", "stop", "hold"]) { vm.pauseSelected() })
        }
        if selected.contains(where: { $0.status == .paused || $0.status == .queued }) {
            list.append(PaletteCommand(id: "sel.resume", title: L10n.t("Resume Selected (%d)", count),
                                       subtitle: L10n.t("Start the selected downloads"),
                                       symbol: "play.fill", group: .selection, shortcut: "⌥⌘P",
                                       keywords: ["resume", "start"]) { vm.resumeSelected() })
        }
        if selected.contains(where: { $0.status.isFailed }) {
            list.append(PaletteCommand(id: "sel.retry", title: L10n.t("Retry Selected (%d)", count),
                                       subtitle: L10n.t("Try the failed ones again"),
                                       symbol: "arrow.clockwise", group: .selection, shortcut: "⌘R",
                                       keywords: ["retry", "again", "failed"]) { vm.retrySelected() })
        }
        if let first = selected.first(where: { $0.status.hasData }) {
            list.append(PaletteCommand(id: "sel.reveal", title: L10n.t("Show in Finder"),
                                       subtitle: first.name,
                                       symbol: "folder", group: .selection,
                                       keywords: ["finder", "reveal", "folder"]) { vm.revealInFinder(first) })
        }
        list.append(PaletteCommand(id: "sel.copy", title: count == 1 ? L10n.t("Copy Source Link")
                                                                   : L10n.t("Copy %d Source Links", count),
                                   subtitle: L10n.t("The URLs or magnets, one per line"),
                                   symbol: "link", group: .selection,
                                   keywords: ["copy", "url", "link", "magnet"]) {
            vm.copyToPasteboard(selected.map(\.sourceLocator).joined(separator: "\n"))
        })
        list.append(PaletteCommand(id: "sel.top", title: L10n.t("Move to Top of Queue"),
                                   subtitle: L10n.t("Start these before everything else waiting"),
                                   symbol: "arrow.up.to.line", group: .selection,
                                   keywords: ["queue", "first", "priority", "top"]) {
            vm.moveInQueue(selected.map(\.id), to: .top)
        })
        return list
    }

    /// Downloads whose name contains the query: running one jumps to its row.
    private func taskCommands(_ needle: String) -> [PaletteCommand] {
        vm.tasks
            .filter { $0.name.lowercased().contains(needle) }
            .prefix(8)
            .map { task in
                PaletteCommand(id: "task.\(task.id.uuidString)", title: task.name,
                               subtitle: task.statusDetailText,
                               symbol: task.fileType.symbol, group: .task) { vm.reveal(task.id) }
            }
    }

    /// One settings row, opened in its pane with the row highlighted.
    private func settingsRowCommands(_ needle: String) -> [PaletteCommand] {
        SettingsSearch.rows(matching: needle).map { row in
            PaletteCommand(id: "row.\(row.pane.id).\(row.title)", title: row.title,
                           subtitle: L10n.t("%1$@ › %2$@", row.pane.group.title, L10n.t(row.pane.rawValue)),
                           symbol: row.pane.symbol, group: .settings) {
                SettingsRoute.shared.request(row.pane, highlight: row.title)
                openSettings()
            }
        }
    }

    private var addCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "add.sheet", title: L10n.t("Add Download…"),
                           subtitle: L10n.t("Paste a URL, magnet, or .m3u8 stream"),
                           symbol: "plus.circle", group: .add, shortcut: "⌘N",
                           keywords: ["new", "url", "magnet", "torrent", "link", "hls"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "add.clipboard", title: L10n.t("Paste URLs from Clipboard"),
                           subtitle: L10n.t("Queue every link on the pasteboard, one per line"),
                           symbol: "doc.on.clipboard", group: .add, shortcut: "⌘⇧V",
                           keywords: ["paste", "batch", "bulk"]) {
                guard let text = NSPasteboard.general.string(forType: .string),
                      !text.isEmpty else {
                    vm.toastWarning(L10n.t("Nothing on the clipboard"))
                    return
                }
                vm.add(rawLines: text, saveDirectory: nil, priority: .normal)
            },
            PaletteCommand(id: "add.grabber", title: L10n.t("Grab Links from Page…"),
                           subtitle: L10n.t("List every file linked from a page and pick from it"),
                           symbol: "link.badge.plus", group: .add, shortcut: "⌘⇧L",
                           keywords: ["scrape", "extract", "page", "links"]) {
                vm.isLinkGrabberPresented = true
            },
            PaletteCommand(id: "add.basket", title: L10n.t("Show Drop Basket"),
                           subtitle: L10n.t("A small always-on-top target for dragging links onto"),
                           symbol: "tray.and.arrow.down", group: .add, shortcut: "⌘⇧B",
                           keywords: ["drag", "drop", "float", "basket"]) {
                DropBasketController.shared.toggle()
            },
        ]
    }

    private var downloadCommands: [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(id: "dl.startAll", title: L10n.t("Start All Downloads"),
                           subtitle: L10n.t("Resume everything paused or queued"),
                           symbol: "play.fill", group: .downloads,
                           keywords: ["resume", "unpause"]) { vm.resumeAll() },
            PaletteCommand(id: "dl.pauseAll", title: L10n.t("Pause All Downloads"),
                           subtitle: L10n.t("Hold every active transfer"),
                           symbol: "pause.fill", group: .downloads,
                           keywords: ["stop", "hold"]) { vm.pauseAll() },
            PaletteCommand(id: "dl.retryFailed", title: L10n.t("Retry All Failed"),
                           subtitle: L10n.t("Try every failed download again"),
                           symbol: "arrow.clockwise", group: .downloads,
                           keywords: ["retry", "failed", "error", "again"]) { vm.retryAllFailed() },
            PaletteCommand(id: "dl.clearCompleted", title: L10n.t("Clear Completed"),
                           subtitle: L10n.t("Take finished rows off the list — files stay on disk"),
                           symbol: "checkmark.circle", group: .downloads,
                           keywords: ["clear", "completed", "finished", "tidy", "clean"]) { vm.clearCompleted() },
            PaletteCommand(id: "dl.snail", title: L10n.t("Toggle Speed Limit"),
                           subtitle: L10n.t("Switch between Unlimited and the active traffic profile"),
                           symbol: "tortoise", group: .downloads,
                           keywords: ["throttle", "snail", "slow", "bandwidth"]) { vm.toggleSnail() },
        ]
        for profile in vm.settings.profiles {
            list.append(PaletteCommand(
                id: "dl.profile.\(profile.name)",
                title: L10n.t("Traffic Profile: %@", profile.name),
                subtitle: profile.name == vm.settings.selectedProfileName
                    ? L10n.t("Currently active")
                    : L10n.t("Switch the global speed and connection limits"),
                symbol: "speedometer", group: .downloads,
                keywords: ["profile", "limit", "speed", profile.name])
            { vm.setProfile(profile.name) })
        }
        for server in vm.servers {
            list.append(PaletteCommand(
                id: "dl.server.\(server.id)", title: L10n.t("Connect to %@", server.label),
                subtitle: L10n.t("Browse this SFTP server"),
                symbol: "server.rack", group: .downloads,
                keywords: ["sftp", "server", "ssh", "connect", server.label])
            { vm.selectServer(server.id) })
        }
        list.append(contentsOf: [
            PaletteCommand(id: "dl.stats", title: L10n.t("Statistics…"),
                           subtitle: L10n.t("Totals, throughput history, and per-kind breakdown"),
                           symbol: "chart.bar", group: .downloads, shortcut: "⌘Y",
                           keywords: ["graph", "totals", "usage"]) { vm.isStatsPresented = true },
            PaletteCommand(id: "dl.history", title: L10n.t("History…"),
                           subtitle: L10n.t("Finished downloads, re-download, CSV export"),
                           symbol: "clock.arrow.circlepath", group: .downloads, shortcut: "⌘⇧Y",
                           keywords: ["past", "completed", "csv", "export"]) { vm.isHistoryPresented = true },
            PaletteCommand(id: "dl.updates", title: L10n.t("Check for Updates…"),
                           subtitle: L10n.t("Asks the release feed once, when you press it"),
                           symbol: "arrow.down.app", group: .downloads,
                           keywords: ["version", "upgrade", "release"]) { vm.checkForUpdates() },
        ])
        return list
    }

    private var viewCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "view.detail", title: L10n.t("Toggle Detail Panel"),
                           subtitle: L10n.t("Files, peers, trackers, and per-task limits"),
                           symbol: "sidebar.right", group: .view, shortcut: "⌘I",
                           keywords: ["inspector", "panel", "info"]) {
                vm.detailPanelVisible.toggle()
            },
            PaletteCommand(id: "view.detailPosition", title: L10n.t("Move Detail Panel"),
                           subtitle: L10n.t("Dock it on the right edge or along the bottom"),
                           symbol: "rectangle.split.2x1", group: .view,
                           keywords: ["dock", "bottom", "right", "layout"]) {
                vm.toggleDetailPanelPosition()
            },
        ] + AppTheme.allCases.map { theme in
            PaletteCommand(id: "view.theme.\(theme.settingsValue)",
                           title: L10n.t("Theme: %@", L10n.t(theme.rawValue)),
                           subtitle: theme == vm.theme ? L10n.t("Currently active") : L10n.t("Switch the whole app to this palette"),
                           symbol: "paintpalette", group: .view,
                           keywords: ["theme", "colour", "color", "dark", "light", theme.rawValue])
            { vm.theme = theme }
        }
    }

    private var settingsCommands: [PaletteCommand] {
        SettingsView.Pane.allCases.map { pane in
            PaletteCommand(id: "settings.\(pane.id)",
                           title: L10n.t("Settings: %@", L10n.t(pane.rawValue)),
                           subtitle: Self.paneSummary(pane),
                           symbol: pane.symbol, group: .settings,
                           keywords: Self.paneKeywords(pane))
            { show(pane) }
        }
    }

    private var discoverCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "find.mirrors", title: L10n.t("Mirrors & failover"),
                           subtitle: L10n.t("Add sheet ▸ Mirrors — segments spread across alternate URLs and fail over"),
                           symbol: "arrow.triangle.branch", group: .discover,
                           keywords: ["mirror", "metalink", "failover", "alternate", "redundant"]) {
                openAddWithAdvanced()
            },
            PaletteCommand(id: "find.checksum", title: L10n.t("Verify a checksum"),
                           subtitle: L10n.t("Add sheet ▸ Checksum — MD5/SHA-1/SHA-256, checked when the download finishes"),
                           symbol: "checkmark.seal", group: .discover,
                           keywords: ["checksum", "hash", "sha256", "md5", "integrity", "verify"]) {
                openAddWithAdvanced()
            },
            PaletteCommand(id: "find.cookies", title: L10n.t("Sign-in cookies for a download"),
                           subtitle: L10n.t("Add sheet ▸ Sign-in cookies — for files behind a login"),
                           symbol: "person.badge.key", group: .discover,
                           keywords: ["cookie", "login", "session", "auth", "paywall"]) {
                openAddWithAdvanced()
            },
            PaletteCommand(id: "find.filePriority", title: L10n.t("Per-file priority in a torrent"),
                           subtitle: L10n.t("Select a torrent, then the detail panel's Files tab — skip, low, normal, high"),
                           symbol: "list.bullet.indent", group: .discover,
                           keywords: ["priority", "files", "torrent", "skip", "select"]) {
                vm.detailPanelVisible = true
                vm.detailTab = .files
                if vm.selectedTask == nil {
                    vm.toastWarning(L10n.t("Select a torrent to set per-file priority"))
                }
            },
            PaletteCommand(id: "find.applescript", title: L10n.t("Automate with AppleScript"),
                           subtitle: L10n.t("Copies a working example — add download, pause all, count downloads"),
                           symbol: "applescript", group: .discover,
                           keywords: ["applescript", "automation", "script", "shortcuts", "osascript"]) {
                vm.copyToPasteboard(Self.appleScriptExample)
                vm.toastSuccess(L10n.t("AppleScript example copied"))
            },
        ]
    }

    /// These fields live on the review step, so say what to do first and have them open there.
    private func openAddWithAdvanced() {
        vm.addSheetRevealsAdvanced = true
        vm.isAddSheetPresented = true
        vm.toastNow(L10n.t("Paste a link — Advanced options will be open on the next step"))
    }

    private static let appleScriptExample = """
    tell application "Goel°"
        add download "https://example.com/file.zip"
        count downloads
    end tell
    """

    private static func paneSummary(_ pane: SettingsView.Pane) -> String {
        switch pane {
        case .general:     return L10n.t("Theme, language, default folder, clipboard capture, ffmpeg")
        case .network:     return L10n.t("Proxy, timeouts, retries, saved per-host credentials")
        case .aggregation: return L10n.t("Combine Wi-Fi and Ethernet on one download")
        case .traffic:     return L10n.t("Three switchable speed and connection profiles")
        case .bittorrent:  return L10n.t("DHT, PeX, encryption, and the .torrent watch folder")
        case .scheduler:   return L10n.t("Daily download window and what happens when the queue drains")
        case .rss:         return L10n.t("Watch feeds and queue matching items automatically")
        case .advanced:    return L10n.t("Notifications, power, post-download actions, backup, diagnostics")
        case .antivirus:   return L10n.t("Run an external scanner over finished files")
        case .browser:     return L10n.t("The extension, the helper, the bookmarklet, the URL scheme")
        case .remote:      return L10n.t("Reach your queue from a phone or another machine")
        case .audit:       return L10n.t("Local, on-disk record of what was downloaded")
        case .license:     return L10n.t("Personal use, commercial licensing, and what the app never does")
        }
    }

    private static func paneKeywords(_ pane: SettingsView.Pane) -> [String] {
        switch pane {
        case .general:     return ["theme", "folder", "language", "clipboard", "ffmpeg", "subtitles"]
        case .network:     return ["proxy", "socks", "timeout", "retry", "user agent", "credentials", "password"]
        case .aggregation: return ["aggregation", "multipath", "wifi", "ethernet", "adapter", "bonding"]
        case .traffic:     return ["speed", "limit", "throttle", "connections", "seed ratio", "profile"]
        case .bittorrent:  return ["torrent", "dht", "pex", "encryption", "watch folder", "magnet", "seeding"]
        case .scheduler:   return ["schedule", "window", "night", "shutdown", "sleep", "quit"]
        case .rss:         return ["rss", "feed", "atom", "podcast", "auto download", "subscribe"]
        case .advanced:    return ["notifications", "battery", "sleep", "backup", "script", "extract",
                                   "diagnostics", "support", "updates"]
        case .antivirus:   return ["antivirus", "scan", "clamav", "virus", "malware"]
        case .browser:     return ["browser", "extension", "chrome", "firefox", "safari", "bookmarklet", "capture"]
        case .remote:      return ["remote", "web", "portal", "phone", "lan", "tls", "server"]
        case .audit:       return ["audit", "log", "compliance", "record", "retention"]
        case .license:     return ["licence", "license", "commercial", "work", "business", "polyform", "legal"]
        }
    }

    private func show(_ pane: SettingsView.Pane) {
        SettingsRoute.shared.request(pane)
        openSettings()
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .scaledFont(size: Theme.TextSize.body)
                    .foregroundStyle(isHighlighted ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .scaledFont(size: Theme.TextSize.title)
                        .lineLimit(1)
                    Text(command.subtitle)
                        .scaledFont(size: Theme.TextSize.meta)
                        // Subtitles say where a command lives: secondary, not tertiary.
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 10)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .scaledFont(size: Theme.TextSize.caption, weight: .medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.t(command.group.rawValue))
                    .scaledFont(size: Theme.TextSize.micro, weight: .semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(isHighlighted ? Theme.accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yGroup(label: A11y.sentence(command.title, L10n.t(command.group.rawValue)),
                   value: command.subtitle,
                   hint: command.shortcut.map { L10n.t("Keyboard shortcut %@.", $0) })
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
