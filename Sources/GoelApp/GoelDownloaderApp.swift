import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The application entry point (invoked from `main.swift`, which first routes
/// `--native-messaging-host` invocations to the stdio extension bridge).
///
/// A small `NSApplicationDelegate` forces the process to behave like a normal
/// foreground GUI app (dock icon + active window) since a bare SwiftUI
/// executable can otherwise launch as a background accessory.
struct GoelDownloaderApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 1040, minHeight: 620)
                .preferredColorScheme(viewModel.preferredColorScheme)
                .task {
                    // `start()` already restores settings and primes notification
                    // authorization; once they're loaded, best-effort claim the
                    // magnet/.torrent handler if the user asked us to be default.
                    await viewModel.start()
                    Self.registerDefaultTorrentHandlersIfWanted(viewModel.settings.btMakeDefaultClient)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { GoelCommands(viewModel: viewModel) }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.preferredColorScheme)
                .frame(width: 760, height: 560)
        }

        // The optional menu-bar status item (the "Rich list" concept). Its
        // presence is bound to the persisted `menuBarExtraEnabled` preference, so
        // the General-pane toggle inserts/removes it live. `.window` style hosts
        // the custom SwiftUI popover instead of a plain menu.
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarView()
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.preferredColorScheme)
        } label: {
            MenuBarSpeedLabel(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }

    /// Drives whether the status-bar item is shown, mirrored to the persisted
    /// ``AppSettings/menuBarExtraEnabled`` preference. Dragging the item out of
    /// the menu bar (⌘-drag) flips the binding, which writes the preference back
    /// off so the Settings toggle stays in sync.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { viewModel.settings.menuBarExtraEnabled },
            set: { newValue in
                // SwiftUI reconciles `isInserted` on every scene update and can
                // write the *current* value straight back. Because `@Published
                // settings` publishes on every assignment (it does not dedupe by
                // equality), an unguarded write here would publish → re-evaluate
                // the scene → write again … a synchronous update loop that
                // overflows the stack. Only commit a genuine change.
                guard newValue != viewModel.settings.menuBarExtraEnabled else { return }
                viewModel.update { $0.menuBarExtraEnabled = newValue }
            }
        )
    }

    /// Best-effort registration as the system handler for `magnet:` links and
    /// `.torrent` files, gated on the BitTorrent "make default client" preference.
    /// Everything here is guarded and any failure is ignored — an unregistered or
    /// not-yet-installed build simply won't be offered as a handler, which must
    /// never surface as an error to the user.
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

/// Forces a normal foreground activation policy and brings the window to front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?
    private let servicesProvider = GoelServicesProvider()
    private let memoryRelief = MemoryReliefService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // Close the trust-on-first-use hole for the GUI: with an approver
        // installed, `SFTPClient` reads an unknown server's host key in a
        // credential-free pre-flight and waits for the user's decision before it
        // authenticates. GoelCore's default is nil — classic learn-on-first-
        // connect — which is the only workable policy where there is nobody to
        // ask, so the daemon, the `sftp://` URL paths and the tests keep it.
        HostKeyTrust.shared.approver = HostKeyApprovalPresenter.shared

        // Return freed heap pages to the OS on system memory pressure, so a
        // transient spike (a big transfer, a directory walk) doesn't leave the
        // resident footprint inflated. Non-destructive — only already-free pages.
        memoryRelief.start()

        // "Download with GoelDownloader" in every app's Services menu.
        app.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        // Set the "Swarm" dock icon, choosing the light/dark appearance variant,
        // and keep it in sync if the system appearance changes at runtime.
        applyDockIcon()
        appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.applyDockIcon()
        }
    }

    /// Closing the last window quits — unless downloads are still running *and*
    /// the menu-bar item is showing, in which case the app stays resident and
    /// keeps transferring. The popover's "Open Goel°" button is the way back to a
    /// window. With the menu-bar item switched off there is no way back, so
    /// staying resident would strand the user with an invisible process; the app
    /// quits, and ``applicationShouldTerminate(_:)`` asks first.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(ActiveWorkGate.shared.hasActiveWork && ActiveWorkGate.shared.menuBarVisible)
    }

    /// Confirm before quitting on top of work in progress.
    ///
    /// Not a duplicate of the check above: that one decides whether a window close
    /// should quit at all, this one covers every other route out — ⌘Q, the Dock
    /// menu, a log-out. The queue's own auto-shutdown drain reaches
    /// `NSApp.terminate(nil)` only once nothing is active, so `hasActiveWork` is
    /// already false there and no alert interrupts it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ActiveWorkGate.shared.hasActiveWork else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Downloads are still running."
        alert.informativeText =
            "Quitting now stops them. Unfinished downloads are kept and can be resumed next launch."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The user switched to another app: download latency no longer matters, so
    /// give any freed-but-resident heap pages back to the OS. Off the main thread
    /// so the walk never stalls the UI.
    func applicationDidResignActive(_ notification: Notification) {
        memoryRelief.reclaimAsync()
    }

    /// Opened URLs: the `goeldownloader://` scheme, `magnet:` links (when we're
    /// the default handler) and double-clicked `.torrent` files. Posts are
    /// buffered until the view model subscribes, so a cold launch via a link
    /// or file never drops the add.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if let payload = ExternalAdd.payload(from: url) {
                    ExternalAdd.post(payload)
                }
            }
        }
    }

    /// Picks the icon variant matching the current effective appearance and sets
    /// it as the dock icon. Falls back silently to the bundled default if a
    /// resource is missing — a missing icon must never crash the app.
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

/// Menu-bar commands that mirror the mockup's File / Downloads / View menus and
/// their keyboard shortcuts.
struct GoelCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        // App menu — a real "About" panel in place of the default about item.
        CommandGroup(replacing: .appInfo) {
            Button("About Goel°") { showAboutPanel() }
            Button("Check for Updates…") { viewModel.checkForUpdates() }
        }
        // File menu — add, the two batch-paste flows, and list export/import.
        CommandGroup(replacing: .newItem) {
            Button("Add Download…") { viewModel.isAddSheetPresented = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Grab Links from Page…") { viewModel.isLinkGrabberPresented = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Paste URLs from Clipboard") { pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Paste URLs from File…") { pasteFromFile() }
            Divider()
            Button("Export Download List…") { exportList() }
            Button("Import Download List…") { importList() }
            Button("Import from Other App…") { importForeign() }
            Divider()
            Button("Export Backup (JSON)…") { exportBackup() }
            Button("Import Backup (JSON)…") { importBackup() }
        }
        CommandMenu("Downloads") {
            Button("Start All") { viewModel.resumeAll() }
            Button("Pause All") { viewModel.pauseAll() }
            Divider()
            Button("Statistics…") { viewModel.isStatsPresented = true }
                .keyboardShortcut("y", modifiers: .command)
            Button("History…") { viewModel.isHistoryPresented = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Picker("When Downloads Finish", selection: autoShutdownBinding) {
                Text("Do Nothing").tag("none")
                Text("Quit Goel°").tag("quit")
                Text("Sleep").tag("sleep")
                Text("Shut Down").tag("shutdown")
            }
        }
        // View menu — panel and theme toggles (both back existing features).
        CommandGroup(after: .sidebar) {
            Button("Toggle Detail Panel") { viewModel.detailPanelVisible.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Toggle Theme") { cycleTheme() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Toggle Drop Basket") { DropBasketController.shared.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            // The palette lives in `RootView`'s state, which a `Commands` body
            // can't reach — hence the notification hop through the bus.
            Button("Command Palette…") { CommandPaletteBus.toggle() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    /// The About box, with the licence stated in it.
    ///
    /// The packaged app carries the same wording in `NSHumanReadableCopyright`,
    /// but a source build has no such key, and this is the one place a user is
    /// likely to look for the terms. Supplying the credits explicitly means the
    /// panel says the same thing either way. Informational text only — nothing
    /// here checks or enforces anything.
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Free for personal use. Commercial and business use requires a paid licence.\n"
                + "Licensed under PolyForm Noncommercial 1.0.0 — see Settings ▸ Licence.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Goel°",
        ])
    }

    // MARK: Command actions

    /// The one-shot queue-drained action, committed like any other preference.
    private var autoShutdownBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.autoShutdownAction },
            set: { newValue in
                guard newValue != viewModel.settings.autoShutdownAction else { return }
                viewModel.update { $0.autoShutdownAction = newValue }
            }
        )
    }

    /// Write settings + the full task list (with progress and resume state) to a
    /// JSON file — the full-fidelity counterpart of the text export.
    private func exportBackup() {
        guard let url = FilePicker.save(name: "GoelDownloader-backup.json", type: .json) else { return }
        viewModel.exportBackup(to: url)
    }

    /// Restore a JSON backup: merge its tasks and adopt its settings.
    private func importBackup() {
        guard let url = FilePicker.openFile(types: [.json]) else { return }
        viewModel.importBackup(from: url)
    }

    /// Read newline-separated URLs/magnets from the pasteboard and queue them.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        viewModel.add(rawLines: text, saveDirectory: nil, priority: .normal)
    }

    /// Pick a plain-text file of URLs/magnets (one per line) and queue them.
    private func pasteFromFile() {
        guard let contents = readTextFile() else { return }
        viewModel.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    /// Write every task's source locator (one per line) to a chosen text file —
    /// the round-trip counterpart of ``importList()``.
    private func exportList() {
        guard let url = FilePicker.save(name: "GoelDownloader-list.txt", type: .plainText) else { return }
        let body = viewModel.tasks.map(\.source.locator).joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            viewModel.toastNow("Download list exported")
        } catch {
            viewModel.toastNow("Export failed")
        }
    }

    /// Re-queue every source locator from a previously exported list.
    private func importList() {
        guard let contents = readTextFile() else { return }
        viewModel.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    /// Import a queue exported by another download manager or browser: read any
    /// file, extract the download locators it contains, and add them.
    private func importForeign() {
        guard let url = FilePicker.openFile(
            message: "Choose a file exported by aria2, JDownloader, IDM, a browser, etc."
        ) else { return }   // cancelled
        guard let data = try? Data(contentsOf: url) else {
            viewModel.toastNow("Couldn’t read that file")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let locators = ForeignImportParser.extractLocators(from: text)
        guard !locators.isEmpty else {
            viewModel.toastNow("No downloadable links found in that file")
            return
        }
        viewModel.add(rawLines: locators.joined(separator: "\n"), saveDirectory: nil, priority: .normal)
        viewModel.toastNow("Imported \(locators.count) link\(locators.count == 1 ? "" : "s")")
    }

    /// Advance the persisted theme to the next case (System → Light → Dark → …).
    private func cycleTheme() {
        let all = AppTheme.allCases
        let next = (all.firstIndex(of: viewModel.theme) ?? 0) + 1
        viewModel.theme = all[next % all.count]
    }

    /// Shared open-panel helper for the file-based paste/import flows; returns the
    /// chosen file's contents, or `nil` if the user cancels or it can't be read.
    private func readTextFile() -> String? {
        guard let url = FilePicker.openFile(types: [.plainText, .text]) else { return nil } // cancelled
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            viewModel.toastNow("Couldn’t read that file")
            return nil
        }
        return contents
    }
}
