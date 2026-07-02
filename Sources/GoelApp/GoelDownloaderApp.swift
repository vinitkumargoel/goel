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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        let name = Bundle.module.url(forResource: preferred, withExtension: "png") != nil ? preferred : fallback
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
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
            Button("About Goel°") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
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
        }
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "GoelDownloader-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.exportBackup(to: url)
    }

    /// Restore a JSON backup: merge its tasks and adopt its settings.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "GoelDownloader-list.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = viewModel.tasks.map(\.source.locator).joined(separator: "\n")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Re-queue every source locator from a previously exported list.
    private func importList() {
        guard let contents = readTextFile() else { return }
        viewModel.add(rawLines: contents, saveDirectory: nil, priority: .normal)
    }

    /// Import a queue exported by another download manager or browser: read any
    /// file, extract the download locators it contains, and add them.
    private func importForeign() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file exported by aria2, JDownloader, IDM, a browser, etc."
        guard panel.runModal() == .OK, let url = panel.url else { return }   // cancelled
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
