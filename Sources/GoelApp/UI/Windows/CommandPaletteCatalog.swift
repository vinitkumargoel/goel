import SwiftUI
import AppKit
import GoelCore

/// Every command the palette offers, built from the live view model.
@MainActor
struct CommandPaletteCatalog {
    let vm: AppViewModel
    /// Opens the Settings window (`openSettings` from the environment).
    let openSettings: () -> Void

    /// The fixed commands, in group order. Downloads and single settings rows join only once
    /// something is typed: listed up front they would bury the commands.
    var commands: [PaletteCommand] {
        selectionCommands + addCommands + windowCommands + queueCommands + panelCommands
            + settingsCommands + themeCommands + discoverCommands
    }

    func searchable(_ needle: String) -> [PaletteCommand] {
        commands + taskCommands(needle) + settingsRowCommands(needle)
    }

    // MARK: Selection

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
                                       subtitle: first.name, symbol: "folder", group: .selection,
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
        list.append(PaletteCommand(id: "sel.remove", title: L10n.t("Remove from List"),
                                   subtitle: L10n.t("Take them off the list — files stay on disk"),
                                   symbol: "minus.circle", group: .selection,
                                   keywords: ["remove", "delete", "clear"]) {
            vm.removeSelected(deleteData: false)
        })
        if selected.contains(where: { $0.status.hasData }) {
            list.append(PaletteCommand(id: "sel.trash", title: L10n.t("Move to Trash…"),
                                       subtitle: L10n.t("Remove them and trash their files, after asking"),
                                       symbol: "trash", group: .selection,
                                       keywords: ["trash", "delete", "files", "remove"]) {
                vm.confirmMoveSelectionToTrash()
            })
        }
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

    // MARK: Adding

    private var addCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "add.sheet", title: L10n.t("Add Download…"),
                           subtitle: L10n.t("Paste a URL, magnet, or .m3u8 stream"),
                           symbol: "plus", group: .add, shortcut: "⌘N",
                           keywords: ["new", "url", "magnet", "torrent", "link", "hls"]) {
                vm.isAddSheetPresented = true
            },
            PaletteCommand(id: "add.clipboard", title: L10n.t("Paste URLs from Clipboard"),
                           subtitle: L10n.t("Review every link on the pasteboard, one per line"),
                           symbol: "doc.on.clipboard", group: .add, shortcut: "⇧⌘V",
                           keywords: ["paste", "batch", "bulk"]) {
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                    vm.toastWarning(L10n.t("Nothing on the clipboard"))
                    return
                }
                vm.addFromClipboard()
            },
            PaletteCommand(id: "add.grabber", title: L10n.t("Grab Links from Page…"),
                           subtitle: L10n.t("List every file linked from a page and pick from it"),
                           symbol: "link.badge.plus", group: .add, shortcut: "⇧⌘L",
                           keywords: ["scrape", "extract", "page", "links"]) {
                vm.isLinkGrabberPresented = true
            },
            PaletteCommand(id: "add.file", title: L10n.t("Paste URLs from File…"),
                           subtitle: L10n.t("Add every link in a text file"),
                           symbol: "doc.text", group: .add,
                           keywords: ["import", "text", "batch", "bulk", "file"]) {
                MenuActions.pasteFromFile(vm)
            },
            PaletteCommand(id: "add.importList", title: L10n.t("Import Download List…"),
                           subtitle: L10n.t("Add the links from a list you exported"),
                           symbol: "square.and.arrow.down", group: .add,
                           keywords: ["import", "list", "txt"]) { MenuActions.importList(vm) },
            PaletteCommand(id: "add.exportList", title: L10n.t("Export Download List…"),
                           subtitle: L10n.t("Save every link in the list to a text file"),
                           symbol: "square.and.arrow.up", group: .add,
                           keywords: ["export", "list", "txt", "save"]) { MenuActions.exportList(vm) },
            PaletteCommand(id: "add.foreign", title: L10n.t("Import from Other App…"),
                           subtitle: L10n.t("Bring links from aria2, JDownloader, IDM or a browser export"),
                           symbol: "tray.and.arrow.down", group: .add,
                           keywords: ["import", "aria2", "jdownloader", "idm", "migrate", "other"]) {
                MenuActions.importForeign(vm)
            },
            PaletteCommand(id: "add.sftp", title: L10n.t("Add SFTP Server"),
                           subtitle: L10n.t("Save a server to browse and transfer files"),
                           symbol: "server.rack", group: .add,
                           keywords: ["sftp", "ssh", "server", "remote", "connect"]) { vm.presentNewServer() },
        ]
    }

    // MARK: Windows

    private var windowCommands: [PaletteCommand] {
        var list = [
            PaletteCommand(id: "dl.history", title: L10n.t("History…"),
                           subtitle: L10n.t("Finished downloads, re-download, CSV export"),
                           symbol: "clock.arrow.circlepath", group: .windows, shortcut: "⇧⌘Y",
                           keywords: ["past", "completed", "csv", "export"]) { vm.isHistoryPresented = true },
            PaletteCommand(id: "dl.stats", title: L10n.t("Statistics…"),
                           subtitle: L10n.t("Totals, throughput history, and per-kind breakdown"),
                           symbol: "chart.bar", group: .windows, shortcut: "⌘Y",
                           keywords: ["graph", "totals", "usage"]) { vm.isStatsPresented = true },
            PaletteCommand(id: "add.rss", title: L10n.t("Open RSS Feeds"),
                           subtitle: L10n.t("Read feeds, and edit what each one downloads"),
                           symbol: "dot.radiowaves.up.forward", group: .windows,
                           keywords: ["rss", "feed", "atom", "podcast", "rules"]) {
                vm.closeServerBrowser()
                RSSReaderModel.shared.open()
            },
            PaletteCommand(id: "add.basket", title: L10n.t("Toggle Drop Basket"),
                           subtitle: L10n.t("A small always-on-top target for dragging links onto"),
                           symbol: "basket", group: .windows, shortcut: "⇧⌘B",
                           keywords: ["drag", "drop", "float", "basket"]) {
                DropBasketController.shared.toggle()
            },
            PaletteCommand(id: "add.createTorrent", title: L10n.t("Create Torrent…"),
                           subtitle: L10n.t("Make a .torrent from a file or folder, and seed it"),
                           symbol: "doc.badge.plus", group: .windows,
                           keywords: ["create", "make", "torrent", "seed", "share"]) {
                CreateTorrentWindow.shared.show()
            },
        ]
        for server in vm.servers {
            list.append(PaletteCommand(
                id: "dl.server.\(server.id)", title: L10n.t("Connect to %@", server.label),
                subtitle: L10n.t("Browse this SFTP server"),
                symbol: "server.rack", group: .windows,
                keywords: ["sftp", "server", "ssh", "connect", server.label]) { vm.selectServer(server.id) })
        }
        return list
    }

    // MARK: Queue

    private var queueCommands: [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(id: "dl.startAll", title: L10n.t("Resume All"),
                           subtitle: L10n.t("Resume everything paused or queued"),
                           symbol: "play.fill", group: .queue,
                           keywords: ["resume", "unpause"]) { vm.resumeAll() },
            PaletteCommand(id: "dl.selectCompleted", title: L10n.t("Select Completed"),
                           subtitle: L10n.t("Select every finished download in the list"),
                           symbol: "checkmark.circle.fill", group: .queue,
                           keywords: ["select", "completed", "finished", "done"]) { vm.selectCompleted() },
            PaletteCommand(id: "dl.pauseAll", title: L10n.t("Pause All Downloads"),
                           subtitle: L10n.t("Hold every active transfer"),
                           symbol: "pause.fill", group: .queue,
                           keywords: ["stop", "hold"]) { vm.pauseAll() },
            PaletteCommand(id: "dl.retryFailed", title: L10n.t("Retry All Failed"),
                           subtitle: L10n.t("Try every failed download again"),
                           symbol: "arrow.clockwise", group: .queue,
                           keywords: ["retry", "failed", "error", "again"]) { vm.retryAllFailed() },
            PaletteCommand(id: "dl.clearCompleted", title: L10n.t("Clear Completed"),
                           subtitle: L10n.t("Take finished rows off the list — files stay on disk"),
                           symbol: "checkmark.circle", group: .queue,
                           keywords: ["clear", "completed", "finished", "tidy", "clean"]) { vm.clearCompleted() },
            PaletteCommand(id: "dl.snail", title: L10n.t("Toggle Speed Limit"),
                           subtitle: L10n.t("Switch between Unlimited and the active speed profile"),
                           symbol: "tortoise", group: .queue,
                           keywords: ["throttle", "snail", "slow", "bandwidth"]) { vm.toggleSnail() },
        ]
        for profile in vm.settings.profiles {
            list.append(PaletteCommand(
                id: "dl.profile.\(profile.name)",
                title: L10n.t("Speed Profile: %@", profile.name),
                subtitle: profile.name == vm.settings.selectedProfileName
                    ? L10n.t("Currently active")
                    : L10n.t("Switch the global speed and connection limits"),
                symbol: "gauge.with.dots.needle.33percent", group: .queue,
                keywords: ["profile", "limit", "speed", profile.name]) { vm.setProfile(profile.name) })
        }
        return list
    }

    // MARK: Panels

    private var panelCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "view.sidebar", title: L10n.t("Toggle Sidebar"),
                           subtitle: L10n.t("Hide the filters to give the list the width"),
                           symbol: "sidebar.left", group: .panels, shortcut: "⌃⌘S",
                           keywords: ["sidebar", "filters", "narrow", "hide"]) {
                vm.sidebarVisible.toggle()
            },
            PaletteCommand(id: "view.density", title: L10n.t("Toggle Compact Rows"),
                           subtitle: ListDensity.stored == .compact
                               ? L10n.t("Back to two-line rows")
                               : L10n.t("One-line rows with a thin progress bar"),
                           symbol: "list.bullet", group: .panels, shortcut: "⌥⌘C",
                           keywords: ["density", "compact", "regular", "rows", "dense"]) {
                ListDensity.toggleStored()
            },
            PaletteCommand(id: "view.detail", title: L10n.t("Toggle Detail Panel"),
                           subtitle: L10n.t("Files, peers, trackers, and per-task limits"),
                           symbol: "sidebar.right", group: .panels, shortcut: "⌘I",
                           keywords: ["inspector", "panel", "info"]) {
                vm.detailPanelVisible.toggle()
            },
            PaletteCommand(id: "view.detailPosition", title: L10n.t("Move Detail Panel"),
                           subtitle: vm.detailDockForcedBottom
                               ? L10n.t("Held at the bottom: the window is too narrow for a right dock")
                               : L10n.t("Dock it on the right edge or along the bottom"),
                           symbol: "rectangle.split.2x1", group: .panels,
                           keywords: ["dock", "bottom", "right", "layout"]) {
                if vm.detailDockForcedBottom {
                    vm.toastWarning(L10n.t("Widen the window to dock the panel on the right"))
                } else {
                    vm.toggleDetailPanelPosition()
                }
            },
        ]
    }

    // MARK: Settings

    private var settingsCommands: [PaletteCommand] {
        SettingsView.Pane.allCases.map { pane in
            PaletteCommand(id: "settings.\(pane.id)",
                           title: L10n.t("Settings: %@", L10n.t(pane.rawValue)),
                           subtitle: CommandPaletteText.paneSummary(pane),
                           symbol: pane.symbol, group: .settings,
                           keywords: CommandPaletteText.paneKeywords(pane)) { show(pane) }
        } + [
            PaletteCommand(id: "settings.exportBackup", title: L10n.t("Export Backup (JSON)…"),
                           subtitle: L10n.t("Save the list and settings to a file"),
                           symbol: "externaldrive.badge.plus", group: .settings,
                           keywords: ["backup", "export", "save", "json"]) { MenuActions.exportBackup(vm) },
            PaletteCommand(id: "settings.importBackup", title: L10n.t("Import Backup (JSON)…"),
                           subtitle: L10n.t("Restore the list and settings from a backup"),
                           symbol: "externaldrive.badge.checkmark", group: .settings,
                           keywords: ["backup", "import", "restore", "json"]) { MenuActions.importBackup(vm) },
            PaletteCommand(id: "help.setup", title: L10n.t("Show Setup Again…"),
                           subtitle: L10n.t("Reopen the first-run checks and browser setup"),
                           symbol: "wand.and.stars", group: .settings,
                           keywords: ["onboarding", "welcome", "first run", "setup", "browser", "extension"]) {
                OnboardingState.requestShowAgain()
            },
            PaletteCommand(id: "dl.updates", title: L10n.t("Check for Updates…"),
                           subtitle: L10n.t("Asks the release feed once, when you press it"),
                           symbol: "arrow.down.app", group: .settings,
                           keywords: ["version", "upgrade", "release"]) { vm.checkForUpdates() },
        ]
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

    private func show(_ pane: SettingsView.Pane) {
        SettingsRoute.shared.request(pane)
        openSettings()
    }

    // MARK: Appearance

    private var themeCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "view.theme.toggle", title: L10n.t("Toggle Theme"),
                           subtitle: L10n.t("Flip between light and dark"),
                           symbol: "circle.lefthalf.filled", group: .theme, shortcut: "⇧⌘T",
                           keywords: ["theme", "appearance", "dark", "light", "mode"]) {
                vm.toggleAppearanceMode()
            },
        ] + StudioAppearanceMode.allCases.map { mode in
            PaletteCommand(id: "view.theme.\(mode.storedValue)",
                           title: L10n.t("Theme: %@", mode.title),
                           subtitle: mode == vm.appearanceMode
                               ? L10n.t("Currently active")
                               : mode == .system ? L10n.t("Follow the Mac’s light or dark setting")
                                                 : L10n.t("Switch the whole app to this appearance"),
                           symbol: mode.symbol, group: .theme,
                           keywords: ["theme", "appearance", "colour", "color", "dark", "light", mode.rawValue]) {
                vm.appearanceMode = mode
            }
        }
    }

    // MARK: Where is…

    private var discoverCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "find.mirrors", title: L10n.t("Mirrors & failover"),
                           subtitle: L10n.t("Add sheet ▸ Mirrors — segments spread "
                               + "across alternate URLs and fail over"),
                           symbol: "arrow.triangle.branch", group: .discover,
                           keywords: ["mirror", "metalink", "failover", "alternate", "redundant"]) {
                openAddWithAdvanced()
            },
            PaletteCommand(id: "find.checksum", title: L10n.t("Verify a checksum"),
                           subtitle: L10n.t("Add sheet ▸ Checksum — MD5/SHA-1/SHA-256, "
                               + "checked when the download finishes"),
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
                           subtitle: L10n.t("Select a torrent, then the detail panel’s "
                               + "Files tab — skip, low, normal, high"),
                           symbol: "list.bullet.indent", group: .discover,
                           keywords: ["priority", "files", "torrent", "skip", "select"]) {
                vm.detailPanelVisible = true
                vm.detailTab = .files
                if let task = vm.selectedTask {
                    if !DetailTab.available(for: task).contains(.files) {
                        vm.toastWarning(L10n.t("“%@” is a single file — per-file priority is for "
                            + "torrents and multi-file downloads", task.name))
                    }
                } else {
                    vm.toastWarning(L10n.t("Select a torrent to set per-file priority"))
                }
            },
            PaletteCommand(id: "find.applescript", title: L10n.t("Automate with AppleScript"),
                           subtitle: L10n.t("Copies a working example — add download, pause all, count downloads"),
                           symbol: "applescript", group: .discover,
                           keywords: ["applescript", "automation", "script", "shortcuts", "osascript"]) {
                vm.copyToPasteboard(CommandPaletteText.appleScriptExample)
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
}
