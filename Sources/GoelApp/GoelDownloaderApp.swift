import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct GoelDownloaderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Held, never observed: `body` re-ran on every 10 Hz snapshot when this was a `@StateObject`.
    /// The scenes need only the colour scheme and the menu-bar switch, which ``AppAppearance`` carries.
    private let viewModel: AppViewModel
    @ObservedObject private var appearance: AppAppearance

    init() {
        let model = AppViewModel()
        viewModel = model
        appearance = model.appearance
    }

    var body: some Scene {
        // Needs an id so the menu bar can reopen it with `openWindow` after the last window closes.
        WindowGroup(id: MainWindowID.value) {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.telemetry)
                .environmentObject(viewModel.sftpStore)
                .frame(minWidth: 1040, minHeight: 620)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    await viewModel.start()
                    Self.registerDefaultTorrentHandlersIfWanted(viewModel.settings.btMakeDefaultClient)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { GoelCommands(viewModel: viewModel, state: viewModel.commandState) }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.telemetry)
                .environmentObject(viewModel.sftpStore)
                .preferredColorScheme(appearance.colorScheme)
                .frame(width: 760, height: 560)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.telemetry)
                .environmentObject(viewModel.sftpStore)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            MenuBarSpeedLabel(telemetry: viewModel.telemetry)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { appearance.menuBarExtraEnabled },
            set: { newValue in
                // SwiftUI writes the current value back on every scene update and `@Published` doesn't dedupe — an unguarded write recurses until the stack overflows.
                guard newValue != viewModel.settings.menuBarExtraEnabled else { return }
                viewModel.update { $0.menuBarExtraEnabled = newValue }
            }
        )
    }

    private static func registerDefaultTorrentHandlersIfWanted(_ wanted: Bool) {
        guard wanted else { return }
        let appURL = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "magnet")
        if let torrentType = UTType(filenameExtension: "torrent") {
            workspace.setDefaultApplication(at: appURL, toOpen: torrentType)
        }
    }
}

/// `NSMenuItemValidation` is declared, not just implemented: a plain `validateMenuItem` on an
/// NSObject subclass is invisible to the Objective-C runtime, so AppKit would never call it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var appearanceObservation: NSKeyValueObservation?
    private let servicesProvider = GoelServicesProvider()
    private let memoryRelief = MemoryReliefService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // Closes the trust-on-first-use hole for the GUI: with an approver installed `SFTPClient` waits for the user before authenticating (GoelCore's nil default suits the headless daemon).
        HostKeyTrust.shared.approver = HostKeyApprovalPresenter.shared

        // Before any banner: a click that launches the app goes to whatever delegate is set by now.
        MainActor.assumeIsolated { NotificationService.install() }

        memoryRelief.start()

        app.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        applyDockIcon()
        appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.applyDockIcon()
        }
    }

    /// Stay resident only while the menu-bar item is showing; without it the process would be invisible and unreachable.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(ActiveWorkGate.shared.hasActiveWork && ActiveWorkGate.shared.menuBarVisible)
    }

    /// Not a duplicate of the check above: that covers window close, this covers ⌘Q, the Dock menu and log-out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var cancelConversions = false
        if ActiveWorkGate.shared.hasActiveWork {
            let converting = MainActor.assumeIsolated { AppViewModel.shared?.mediaJobs.hasLiveWork } ?? false
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = converting ? L10n.t("Work is still in progress.")
                                           : L10n.t("Downloads are still running.")
            alert.informativeText = converting
                ? L10n.t("Quitting now stops it. Unfinished downloads are kept and pick up where they left off "
                + "the next time you open Goel°; a conversion in progress is cancelled and its partial file removed.")
                : L10n.t("Quitting now stops them. They’re kept and pick up where they left off the next time you open Goel°.")
            alert.addButton(withTitle: L10n.t("Quit"))
            alert.addButton(withTitle: L10n.t("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            cancelConversions = converting
        }
        // `.terminateLater` on every path, idle included: database writes are queued on a background
        // drain, so terminating at once loses them — and ffmpeg cleanup runs on exit and needs us
        // alive, or the child is orphaned and its partial file left behind.
        Task { @MainActor in
            if cancelConversions {
                AppViewModel.shared?.mediaJobs.cancelAll()
                await AppViewModel.shared?.mediaJobs.waitForShutdown()
            }
            await AppViewModel.shared?.shutdownCore()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        memoryRelief.reclaimAsync()
    }

    /// Standard Edit ▸ Select All (⌘A). Answering it here, at the end of the responder chain,
    /// keeps the menu item enabled for the download queue while a focused text field — which sits
    /// ahead of the delegate in that chain — still gets ⌘A for its own text.
    @objc func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated { AppViewModel.shared?.selectAll() }
    }

    /// Only this delegate's own actions reach here, so everything else validates untouched.
    /// An empty queue greys Select All out rather than offering a command with nothing to select.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(selectAll(_:)) else { return true }
        return MainActor.assumeIsolated { AppViewModel.shared?.visibleTasks.isEmpty == false }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if let payload = ExternalAdd.payload(from: url) {
                    ExternalAdd.post(payload)
                }
            }
        }
    }

    private func applyDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let preferred = isDark ? "AppIcon-Dark" : "AppIcon-Light"
        let fallback = isDark ? "AppIcon-Light" : "AppIcon-Dark"
        let icons = ResourceBundles.app
        let name = icons?.url(forResource: preferred, withExtension: "png") != nil ? preferred : fallback
        guard let url = icons?.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

/// Menu shortcuts are claimed before the focused view sees the key. These let a text field keep
/// the keys that mean something while typing (⇧⌘V pastes as plain text).
@MainActor
enum TextEditingFocus {
    static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }

    /// True when the key went to the text field instead of the command.
    static func forward(_ selector: Selector) -> Bool {
        guard isEditingText else { return false }
        NSApp.sendAction(selector, to: nil, from: nil)
        return true
    }
}

struct GoelCommands: Commands {
    /// Not observed: the menus rebuild from ``CommandState`` alone, not on every snapshot.
    let viewModel: AppViewModel
    @ObservedObject var state: CommandState

    private var s: CommandState.Snapshot { state.snapshot }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.t("About Goel°")) { showAboutPanel() }
            Button(L10n.t("Check for Updates…")) { viewModel.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("Add Download…")) { viewModel.isAddSheetPresented = true }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("Grab Links from Page…")) { viewModel.isLinkGrabberPresented = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button(L10n.t("Paste URLs from Clipboard")) {
                guard !TextEditingFocus.forward(#selector(NSTextView.pasteAsPlainText(_:))) else { return }
                pasteFromClipboard()
            }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button(L10n.t("Paste URLs from File…")) { pasteFromFile() }
            Divider()
            Button(L10n.t("Export Download List…")) { exportList() }
            Button(L10n.t("Import Download List…")) { importList() }
            Button(L10n.t("Import from Other App…")) { importForeign() }
            Divider()
            Button(L10n.t("Export Backup (JSON)…")) { exportBackup() }
            Button(L10n.t("Import Backup (JSON)…")) { importBackup() }
        }
        // Sits with the standard Select All (⌘A), which the app delegate answers for the queue.
        CommandGroup(after: .pasteboard) {
            Button(L10n.t("Deselect All")) {
                guard !TextEditingFocus.isEditingText else { return }
                viewModel.selectNone()
            }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!s.hasSelection)
            Button(L10n.t("Select Completed")) { viewModel.selectCompleted() }
                .disabled(!s.hasCompletedVisible)
        }
        // Replacing, not appending: the standard group already has Edit ▸ Find ▸ Find… ⌘F, and two
        // items on one key equivalent is a coin toss. The queue's own search is the only find here.
        CommandGroup(replacing: .textEditing) {
            Button(L10n.t("Find…")) { FocusBus.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
        }
        // Nothing here prints, and File ▸ Print… would otherwise share ⌘P with Pause Selected.
        CommandGroup(replacing: .printItem) {}
        CommandMenu(L10n.t("Downloads")) {
            Button(L10n.t("Start All")) { viewModel.resumeAll() }
                .disabled(!s.hasResumable)
            Button(L10n.t("Pause All")) { viewModel.pauseAll() }
                .disabled(!s.hasPausable)
            Divider()
            selectionCommands
            Divider()
            Button(L10n.t("Statistics…")) { viewModel.isStatsPresented = true }
                .keyboardShortcut("y", modifiers: .command)
            Button(L10n.t("History…")) { viewModel.isHistoryPresented = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Picker(L10n.t("When Downloads Finish"), selection: autoShutdownBinding) {
                Text(L10n.t("Do Nothing")).tag(AutoShutdownAction.none)
                Text(L10n.t("Quit Goel°")).tag(AutoShutdownAction.quit)
                Text(L10n.t("Sleep")).tag(AutoShutdownAction.sleep)
                Text(L10n.t("Shut Down")).tag(AutoShutdownAction.shutdown)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.t("Toggle Detail Panel")) { viewModel.detailPanelVisible.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button(L10n.t("Toggle Theme")) { cycleTheme() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(L10n.t("Toggle Drop Basket")) { DropBasketController.shared.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button(L10n.t("Command Palette…")) { CommandPaletteBus.toggle() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    /// The keyboard path to what the row context menu offers. Delete (without ⌘) is handled by
    /// the list itself, so it only fires while the list has focus.
    @ViewBuilder
    private var selectionCommands: some View {
        Button(L10n.t("Pause Selected")) { viewModel.pauseSelected() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!s.selectionCanPause)
        Button(L10n.t("Resume Selected")) { viewModel.resumeSelected() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!s.selectionCanResume)
        Button(L10n.t("Show in Finder")) {
            if let task = viewModel.selectedTasks.first(where: { $0.status.hasData }) {
                viewModel.revealInFinder(task)
            }
        }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!s.selectionHasData)
        Button(L10n.t("Copy Link")) {
            viewModel.copyToPasteboard(viewModel.selectedTasks.map(\.sourceLocator).joined(separator: "\n"))
        }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!s.hasSelection)
        Divider()
        Button(L10n.t("Remove from List")) { viewModel.removeSelected(deleteData: false) }
            .disabled(!s.hasSelection)
        // No ⌘⌫ key equivalent: a menu claims it before any text field, disabled or not, so it ate
        // delete-to-line-start everywhere. The list answers ⌘⌫ itself while it has focus.
        Button(L10n.t("Move to Trash…")) { viewModel.confirmMoveSelectionToTrash() }
            .disabled(!s.selectionHasData)
    }

    /// Credits are supplied explicitly: a source build has no `NSHumanReadableCopyright`, so the panel would otherwise omit the licence.
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: L10n.t("Free for personal use. Commercial and business use requires a paid licence.\n"
                + "Licensed under PolyForm Noncommercial 1.0.0 — see Settings ▸ Licence."),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Goel°",
        ])
    }

    private var autoShutdownBinding: Binding<AutoShutdownAction> {
        Binding(
            get: { s.autoShutdown },
            set: { newValue in
                guard newValue != viewModel.settings.autoShutdown else { return }
                viewModel.update { $0.autoShutdown = newValue }
            }
        )
    }

    private func exportBackup() {
        guard let url = FilePicker.save(name: "GoelDownloader-backup.json", type: .json) else { return }
        viewModel.exportBackup(to: url)
    }

    private func importBackup() {
        guard let url = FilePicker.openFile(types: [.json]) else { return }
        viewModel.importBackup(from: url)
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        viewModel.add(rawLines: text, saveDirectory: nil, priority: .normal)
    }

    private func pasteFromFile() {
        guard let contents = readTextFile() else { return }
        viewModel.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    private func exportList() {
        guard let url = FilePicker.save(name: "GoelDownloader-list.txt", type: .plainText) else { return }
        let body = viewModel.tasks.map(\.source.locator).joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            viewModel.toastNow(L10n.t("Download list exported"))
        } catch {
            viewModel.toastNow(L10n.t("Export failed"))
        }
    }

    private func importList() {
        guard let contents = readTextFile() else { return }
        viewModel.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    private func importForeign() {
        guard let url = FilePicker.openFile(
            message: L10n.t("Choose a file exported by aria2, JDownloader, IDM, a browser, etc.")
        ) else { return }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.toastNow(L10n.t("Couldn’t read that file"))
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let locators = ForeignImportParser.extractLocators(from: text)
        guard !locators.isEmpty else {
            viewModel.toastNow(L10n.t("No downloadable links found in that file"))
            return
        }
        // `add` reports what it queued and what it skipped; a second "Imported N" toast here
        // used to overwrite "All N are already in your list" before anyone could read it.
        viewModel.add(rawLines: locators.joined(separator: "\n"), saveDirectory: nil, priority: .normal)
    }


    private func cycleTheme() {
        let all = AppTheme.allCases
        let next = (all.firstIndex(of: viewModel.theme) ?? 0) + 1
        viewModel.theme = all[next % all.count]
    }

    private func readTextFile() -> String? {
        guard let url = FilePicker.openFile(types: [.plainText, .text]) else { return nil }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            viewModel.toastNow(L10n.t("Couldn’t read that file"))
            return nil
        }
        return contents
    }
}
