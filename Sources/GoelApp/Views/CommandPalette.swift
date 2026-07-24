import SwiftUI
import AppKit
import GoelCore

// ============================================================================
// ⌘K command palette.
//
// The app has genuine depth — RSS auto-download, .torrent watch folders,
// Metalink-style mirror failover, per-file torrent priority, multi-adapter
// aggregation, AppleScript, the remote portal — and almost all of it is behind
// a Settings pane, a detail-panel tab, or a menu the user has no reason to
// open. Depth nobody can find is the same as depth that isn't there.
//
// The palette is one search field over every action *and* every place. Two
// kinds of row, deliberately mixed:
//
// * **Commands** run something (Pause all, Show Drop Basket, Toggle theme).
// * **Places** navigate — they open the Settings window on the right pane, or
//   put the relevant surface on screen. These are what make buried features
//   reachable by name, and they are the reason searching "rss", "watch folder"
//   or "mirror" has to work even though no visible control says those words.
//
// Everything the palette does is reachable another way; nothing here is the
// only path to a feature. It is a shortcut, not an API.
// ============================================================================

// MARK: - Cross-scene plumbing

/// Lets a menu command in another scene raise the palette over the main window.
///
/// `GoelCommands` lives in the `App` body and cannot reach ``RootView``'s state
/// directly, so the toggle travels as a notification that the root observes.
/// A one-way, payload-free signal is deliberately the whole contract.
enum CommandPaletteBus {

    static let toggleNotification = Notification.Name("goel.commandPalette.toggle")

    static func toggle() {
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }
}

/// The Settings pane a "place" row wants shown.
///
/// Opening the Settings *window* is the caller's job (`@Environment(\.openSettings)`
/// is only available inside a view); this only carries **which** pane, which
/// ``SettingsView`` picks up and selects. Keeping the two halves separate means
/// a caller that merely wants to preselect a pane doesn't force a window open.
@MainActor
final class SettingsRoute: ObservableObject {

    static let shared = SettingsRoute()

    /// The pane most recently requested. ``SettingsView`` clears it once it has
    /// switched, so requesting the same pane twice in a row still navigates.
    @Published var requestedPane: SettingsView.Pane?

    private init() {}

    func request(_ pane: SettingsView.Pane) {
        requestedPane = pane
    }
}

// MARK: - Model

/// One palette row.
struct PaletteCommand: Identifiable {

    /// Broad grouping, used for the trailing category label and to keep related
    /// rows together when scores tie.
    enum Group: String {
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
    /// Rendered on the right as a reminder, e.g. `⌘⇧B`. Purely a label — the
    /// real shortcut is registered by the menu command, not here.
    var shortcut: String?
    /// Extra search terms that don't belong in the visible title: the words a
    /// user would actually type ("cookies", "watch folder", "seed ratio").
    var keywords: [String] = []
    let run: () -> Void
}

// MARK: - View

/// The palette sheet: a search field over ``PaletteCommand``s with arrow-key
/// navigation and return-to-run.
struct CommandPalette: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query: String = ""

    /// Index into ``matches``. Clamped on every recompute so a shrinking result
    /// list can never leave the highlight pointing past the end.
    @State private var highlighted: Int = 0

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if matches.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass",
                               title: "No matching command",
                               subtitle: "Try “rss”, “mirror”, “watch folder”, or “cookies”.",
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

    // MARK: Sections

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .a11yDecorative()
            TextField("Search actions and settings…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { runHighlighted() }
                .onChange(of: query) { _, _ in highlighted = 0 }
                .accessibilityLabel("Search actions and settings")
                .accessibilityHint("Use the up and down arrow keys to move through results, return to run.")
                // The highlighted result changes as you type but nothing has
                // focus except the field, so announce what return would run.
                .accessibilityValue(matches.indices.contains(highlighted)
                                    ? "\(matches.count) results, \(matches[highlighted].title) selected"
                                    : "No results")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .a11yButton("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        // The field owns the keyboard, so navigation keys are handled here
        // rather than on the list — otherwise the arrows move the text cursor.
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
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(matches[new].id, anchor: .center)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendKey("↑↓", "Navigate")
            legendKey("↩", "Run")
            legendKey("esc", "Close")
            Spacer()
            Text("\(matches.count) of \(commands.count)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // A key hint strip built from arrow and return glyphs. The same guidance
        // is on the search field as an accessibility hint, where it is actually
        // spoken; here the glyphs would just be read as symbol names.
        .a11yDecorative()
    }

    private func legendKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Keyboard

    private func move(by delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        highlighted = (highlighted + delta + matches.count) % matches.count
        return .handled
    }

    private func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    /// Close first, then act: several commands present a sheet of their own, and
    /// AppKit will not stack a second sheet on a window that is still showing
    /// this one. The hop to the next run loop is what makes that ordering hold.
    private func run(_ command: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async(execute: command.run)
    }

    // MARK: Matching

    /// The visible rows. An empty query shows everything in its natural order,
    /// which doubles as a browsable index of what the app can do.
    private var matches: [PaletteCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }
        return commands
            .compactMap { command -> (PaletteCommand, Int)? in
                guard let score = Self.score(command, needle) else { return nil }
                return (command, score)
            }
            // `sorted(by:)` is not stable, and an unstable sort here would let
            // equally-scoring rows swap places on every keystroke. Carrying the
            // declared position as the tie-break pins them.
            .enumerated()
            .sorted { a, b in
                a.element.1 == b.element.1 ? a.offset < b.offset : a.element.1 > b.element.1
            }
            .map(\.element.0)
    }

    /// Higher is better; `nil` means "no match at all".
    ///
    /// Three tiers rather than a general fuzzy matcher: a title prefix is what
    /// the user meant, a word start inside the title or keywords is very likely
    /// what they meant, and a plain substring anywhere is a long shot worth
    /// keeping at the bottom. Subsequence matching was tried and rejected —
    /// it made three-letter queries match almost everything.
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

    // MARK: The commands

    /// Every row, in browse order. Built fresh on each update so titles that
    /// depend on live state ("Pause all" vs the current traffic profile) stay
    /// truthful.
    private var commands: [PaletteCommand] {
        addCommands + downloadCommands + viewCommands + settingsCommands + discoverCommands
    }

    private var addCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "add.sheet", title: "Add Download…",
                           subtitle: "Paste a URL, magnet, or .m3u8 stream",
                           symbol: "plus.circle", group: .add, shortcut: "⌘N",
                           keywords: ["new", "url", "magnet", "torrent", "link", "hls"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "add.clipboard", title: "Paste URLs from Clipboard",
                           subtitle: "Queue every link on the pasteboard, one per line",
                           symbol: "doc.on.clipboard", group: .add, shortcut: "⌘⇧V",
                           keywords: ["paste", "batch", "bulk"]) {
                guard let text = NSPasteboard.general.string(forType: .string),
                      !text.isEmpty else {
                    vm.toastNow("Nothing on the clipboard")
                    return
                }
                vm.add(rawLines: text, saveDirectory: nil, priority: .normal)
            },
            PaletteCommand(id: "add.grabber", title: "Grab Links from Page…",
                           subtitle: "List every file linked from a page and pick from it",
                           symbol: "link.badge.plus", group: .add, shortcut: "⌘⇧L",
                           keywords: ["scrape", "extract", "page", "links"]) {
                vm.isLinkGrabberPresented = true
            },
            PaletteCommand(id: "add.basket", title: "Show Drop Basket",
                           subtitle: "A small always-on-top target for dragging links onto",
                           symbol: "tray.and.arrow.down", group: .add, shortcut: "⌘⇧B",
                           keywords: ["drag", "drop", "float", "basket"]) {
                DropBasketController.shared.toggle()
            },
        ]
    }

    private var downloadCommands: [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(id: "dl.startAll", title: "Start All Downloads",
                           subtitle: "Resume everything paused or queued",
                           symbol: "play.fill", group: .downloads,
                           keywords: ["resume", "unpause"]) { vm.resumeAll() },
            PaletteCommand(id: "dl.pauseAll", title: "Pause All Downloads",
                           subtitle: "Hold every active transfer",
                           symbol: "pause.fill", group: .downloads,
                           keywords: ["stop", "hold"]) { vm.pauseAll() },
            PaletteCommand(id: "dl.snail", title: "Toggle Speed Limit",
                           subtitle: "Switch between Unlimited and the active traffic profile",
                           symbol: "tortoise", group: .downloads,
                           keywords: ["throttle", "snail", "slow", "bandwidth"]) { vm.toggleSnail() },
        ]
        // One row per configured traffic profile, so "high" or "low" finds the
        // switch without knowing the Traffic Limits pane exists.
        for profile in vm.settings.profiles {
            list.append(PaletteCommand(
                id: "dl.profile.\(profile.name)",
                title: "Traffic Profile: \(profile.name)",
                subtitle: profile.name == vm.settings.selectedProfileName
                    ? "Currently active"
                    : "Switch the global speed and connection limits",
                symbol: "speedometer", group: .downloads,
                keywords: ["profile", "limit", "speed", profile.name])
            { vm.setProfile(profile.name) })
        }
        list.append(contentsOf: [
            PaletteCommand(id: "dl.stats", title: "Statistics…",
                           subtitle: "Totals, throughput history, and per-kind breakdown",
                           symbol: "chart.bar", group: .downloads, shortcut: "⌘Y",
                           keywords: ["graph", "totals", "usage"]) { vm.isStatsPresented = true },
            PaletteCommand(id: "dl.history", title: "History…",
                           subtitle: "Finished downloads, re-download, CSV export",
                           symbol: "clock.arrow.circlepath", group: .downloads, shortcut: "⌘⇧Y",
                           keywords: ["past", "completed", "csv", "export"]) { vm.isHistoryPresented = true },
            PaletteCommand(id: "dl.updates", title: "Check for Updates…",
                           subtitle: "Asks the release feed once, when you press it",
                           symbol: "arrow.down.app", group: .downloads,
                           keywords: ["version", "upgrade", "release"]) { vm.checkForUpdates() },
        ])
        return list
    }

    private var viewCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "view.detail", title: "Toggle Detail Panel",
                           subtitle: "Files, peers, trackers, and per-task limits",
                           symbol: "sidebar.right", group: .view, shortcut: "⌘I",
                           keywords: ["inspector", "panel", "info"]) {
                vm.detailPanelVisible.toggle()
            },
            PaletteCommand(id: "view.detailPosition", title: "Move Detail Panel",
                           subtitle: "Dock it on the right edge or along the bottom",
                           symbol: "rectangle.split.2x1", group: .view,
                           keywords: ["dock", "bottom", "right", "layout"]) {
                vm.toggleDetailPanelPosition()
            },
        ] + AppTheme.allCases.map { theme in
            PaletteCommand(id: "view.theme.\(theme.settingsValue)",
                           title: "Theme: \(theme.rawValue)",
                           subtitle: theme == vm.theme ? "Currently active" : "Switch the whole app to this palette",
                           symbol: "paintpalette", group: .view,
                           keywords: ["theme", "colour", "color", "dark", "light", theme.rawValue])
            { vm.theme = theme }
        }
    }

    /// One row per Settings pane. The subtitle names what actually lives there,
    /// which is what makes searching for a *feature* land on the right pane.
    private var settingsCommands: [PaletteCommand] {
        SettingsView.Pane.allCases.map { pane in
            PaletteCommand(id: "settings.\(pane.id)",
                           title: "Settings: \(pane.rawValue)",
                           subtitle: Self.paneSummary(pane),
                           symbol: pane.symbol, group: .settings,
                           keywords: Self.paneKeywords(pane))
            { show(pane) }
        }
    }

    /// Rows that answer "where is that thing?" for features living inside a
    /// sheet or a detail tab, which no Settings pane would ever surface.
    private var discoverCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "find.mirrors", title: "Mirrors & failover",
                           subtitle: "Add sheet ▸ Mirrors — segments spread across alternate URLs and fail over",
                           symbol: "arrow.triangle.branch", group: .discover,
                           keywords: ["mirror", "metalink", "failover", "alternate", "redundant"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "find.checksum", title: "Verify a checksum",
                           subtitle: "Add sheet ▸ Checksum — MD5/SHA-1/SHA-256, checked when the download finishes",
                           symbol: "checkmark.seal", group: .discover,
                           keywords: ["checksum", "hash", "sha256", "md5", "integrity", "verify"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "find.cookies", title: "Sign-in cookies for a download",
                           subtitle: "Add sheet ▸ Sign-in cookies — for files behind a login",
                           symbol: "person.badge.key", group: .discover,
                           keywords: ["cookie", "login", "session", "auth", "paywall"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "find.filePriority", title: "Per-file priority in a torrent",
                           subtitle: "Select a torrent, then the detail panel's Files tab — skip, low, normal, high",
                           symbol: "list.bullet.indent", group: .discover,
                           keywords: ["priority", "files", "torrent", "skip", "select"]) {
                vm.detailPanelVisible = true
                vm.detailTab = .files
                if vm.selectedTask == nil {
                    vm.toastNow("Select a torrent to set per-file priority")
                }
            },
            PaletteCommand(id: "find.applescript", title: "Automate with AppleScript",
                           subtitle: "Copies a working example — add download, pause all, count downloads",
                           symbol: "applescript", group: .discover,
                           keywords: ["applescript", "automation", "script", "shortcuts", "osascript"]) {
                vm.copyToPasteboard(Self.appleScriptExample)
                vm.toastNow("AppleScript example copied")
            },
        ]
    }

    /// A runnable snippet using the verbs declared in `GoelDownloader.sdef`.
    private static let appleScriptExample = """
    tell application "Goel°"
        add download "https://example.com/file.zip"
        count downloads
    end tell
    """

    private static func paneSummary(_ pane: SettingsView.Pane) -> String {
        switch pane {
        case .general:     return "Theme, language, default folder, clipboard capture, ffmpeg"
        case .network:     return "Proxy, timeouts, retries, saved per-host credentials"
        case .aggregation: return "Combine Wi-Fi and Ethernet on one download"
        case .traffic:     return "Three switchable speed and connection profiles"
        case .bittorrent:  return "DHT, PeX, encryption, and the .torrent watch folder"
        case .scheduler:   return "Daily download window and what happens when the queue drains"
        case .rss:         return "Watch feeds and queue matching items automatically"
        case .advanced:    return "Notifications, power, post-download actions, backup, diagnostics"
        case .antivirus:   return "Run an external scanner over finished files"
        case .browser:     return "The extension, the helper, the bookmarklet, the URL scheme"
        case .remote:      return "Reach your queue from a phone or another machine"
        case .audit:       return "Local, on-disk record of what was downloaded"
        case .license:     return "Personal use, commercial licensing, and what the app never does"
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

    /// Open the Settings window on a specific pane.
    private func show(_ pane: SettingsView.Pane) {
        SettingsRoute.shared.request(pane)
        openSettings()
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let command: PaletteCommand
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isHighlighted ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(command.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 10)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(command.group.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? Theme.accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Symbol, title, subtitle, shortcut and group chip are one command.
        // Highlight is an accent wash only, so state it as a selection trait.
        .a11yGroup(label: A11y.sentence(command.title, command.group.rawValue),
                   value: command.subtitle,
                   hint: command.shortcut.map { "Keyboard shortcut \($0)." })
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
