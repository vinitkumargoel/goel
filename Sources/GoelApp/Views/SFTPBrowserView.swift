import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The main-pane SFTP file browser, shown in place of the download list when a server is selected.
/// Drop from Finder to upload, drag out to download, or hand files to the normal queue.
struct SFTPBrowserView: View {
    @EnvironmentObject private var vm: AppViewModel
    @StateObject private var model: SFTPBrowserModel

    /// The connection/client as most recently handed down by the parent. Plain view properties, not
    /// `@StateObject`, so they always reflect the latest edit; `.onChange` forwards them into the model.
    private let connection: SFTPConnection
    private let client: SFTPClient?

    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SFTPEntry?

    /// The entry currently under the pointer, for the hover highlight (list + grid).
    @State private var hoveredEntry: SFTPEntry.ID?
    /// The folder currently being dragged *onto*, so a drop uploads into it rather than the open
    /// directory. One id at a time, which also suppresses the whole-pane drop hint.
    @State private var folderDropTarget: SFTPEntry.ID?
    /// List vs. grid layout, remembered across launches.
    @AppStorage("sftp.browser.gridView") private var isGrid = false
    /// Live filter for the current directory (client-side, name substring).
    @State private var searchText = ""
    /// Selected entries (multi-select) and the keyboard cursor within the listing.
    @State private var selection: Set<SFTPEntry.ID> = []
    @State private var cursor: SFTPEntry.ID?
    @FocusState private var listFocused: Bool
    /// The entry being renamed (drives the rename alert) + its edit buffer.
    @State private var renaming: SFTPEntry?
    @State private var renameText = ""
    /// Sort + hidden-file preferences, remembered across launches.
    @AppStorage("sftp.browser.sortKey") private var sortKeyRaw = "name"
    @AppStorage("sftp.browser.sortAsc") private var sortAscending = true
    @AppStorage("sftp.browser.showHidden") private var showHidden = false
    /// The entry whose info panel is open, plus what has been fetched for it.
    @State private var infoEntry: SFTPEntry?
    @State private var entryInfo: SFTPEntryInfo?
    /// A folder's recursive size, and the walk that produces it. The walk is cancelled when the panel
    /// closes so a big tree doesn't keep listing after nobody is looking.
    @State private var infoFolderSize: Int64?
    @State private var infoSizeTask: Task<Void, Never>?
    @State private var infoSizeCancel: CancelFlag?
    /// The type-to-select buffer and when it was last extended.
    @State private var typeSelectBuffer = ""
    @State private var typeSelectAt = Date.distantPast
    /// How long a typed prefix stays live. Matches Finder's roughly-one-second window: long enough to
    /// type a word, short enough that returning to the keyboard starts a fresh search.
    private static let typeSelectWindow: TimeInterval = 1.0
    /// Free space on the current folder's volume, or nil when unknown/unsupported.
    @State private var volumeSpace: SFTPVolumeSpace?

    init(connection: SFTPConnection, client: SFTPClient?) {
        self.connection = connection
        self.client = client
        _model = StateObject(wrappedValue: SFTPBrowserModel(connection: connection, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                errorBanner(error)
                Divider()
            }
            searchBar
            entryList
            Divider()
            statusFooter
            let myTransfers = vm.sftpTransfers(for: model.connection.id)
            if !myTransfers.isEmpty {
                Divider()
                transferStrip(myTransfers)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.connection.id) {
            await model.restore()
            await consumeNavigationRequest(vm.sftpBrowserNavigation)
            // Piggy-back OS detection on this already-authenticated session, so it
            // never opens a connection of its own to an un-browsed server.
            vm.detectServerOSIfNeeded(connection, client: client)
        }
        // On an edit the parent re-renders with fresh values but the @StateObject model is kept alive,
        // so forward the new credentials in and re-list or the browser keeps the pre-edit login.
        .onChange(of: connection) {
            model.update(connection: connection, client: client)
            Task { await model.refresh() }
        }
        // Re-list when a transfer changes the current server's contents (e.g. an
        // upload finishes) — the transfer center bumps this on completion.
        .onChange(of: vm.sftpMutationTick) { Task { await model.refresh() } }
        .onChange(of: vm.sftpBrowserNavigation) { _, request in
            Task { await consumeNavigationRequest(request) }
        }
        // Clear stale hover/drop highlight when the listing changes — SFTPEntry ids are just names, so
        // a same-named entry in the new folder must not inherit the old highlight.
        .onChange(of: model.path) {
            hoveredEntry = nil; folderDropTarget = nil; searchText = ""
            selection.removeAll(); cursor = nil
            typeSelectBuffer = ""; typeSelectAt = .distantPast
            closeInfo()
        }
        // Free space is per-volume, so it is re-read whenever the folder changes (a different mount can
        // differ wildly) and after any transfer that moved bytes onto this server.
        .task(id: model.path) { volumeSpace = await model.volumeSpace() }
        .onChange(of: vm.sftpMutationTick) {
            Task { volumeSpace = await model.volumeSpace() }
        }
        .sheet(isPresented: Binding(get: { infoEntry != nil },
                                    set: { if !$0 { closeInfo() } })) {
            if let entry = infoEntry {
                SFTPInfoPanel(entry: entry, info: entryInfo,
                              folderSize: infoFolderSize,
                              isSizing: infoSizeTask != nil,
                              onApplyPermissions: { mode in applyPermissions(entry, mode) },
                              onClose: { closeInfo() })
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { if await model.makeDirectory(named: name) { vm.toastNow("Folder created") } }
            }
        }
        .alert("Delete “\(pendingDelete?.name ?? "")”?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    Task { if await model.delete(entry) { vm.toastNow("Deleted “\(entry.name)”") } }
                }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.isDirectory == true
                 ? "The folder must be empty."
                 : "This permanently removes the file from the server.")
        }
        .alert("Rename “\(renaming?.name ?? "")”",
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let entry = renaming {
                    let newName = renameText
                    Task { if await model.rename(entry, to: newName) { vm.toastNow("Renamed") } }
                }
                renaming = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // Every control in this bar is a bare SF Symbol and `.help` tooltips are pointer-only, so each
            // needs a spoken name. Keyboard shortcuts match the Finder equivalents where one exists.
            Button { vm.closeServerBrowser() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to downloads")
            .a11yButton("Back to downloads")

            // Browser-style back / forward through visited folders.
            Button { Task { await model.goBack() } } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).help("Back")
                .keyboardShortcut("[", modifiers: .command)
                .a11yButton("Back")
            Button { Task { await model.goForward() } } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).help("Forward")
                .keyboardShortcut("]", modifiers: .command)
                .a11yButton("Forward")

            Image(systemName: "lock.rectangle.on.rectangle").foregroundStyle(Theme.indigo)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connection.label).font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                breadcrumbBar
            }
            Spacer(minLength: 8)
            Picker("", selection: $isGrid) {
                Image(systemName: "list.bullet").tag(false)
                    .accessibilityLabel("List")
                Image(systemName: "square.grid.2x2").tag(true)
                    .accessibilityLabel("Grid")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            .help("Switch between list and grid view")
            .accessibilityLabel("View style")

            sortMenu

            Button { Task { await model.goUp() } } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.isAtRoot)
            .help("Parent folder")
            .keyboardShortcut(.upArrow, modifiers: .command)
            .a11yButton("Parent folder")

            Button { chooseUploadItems() } label: { Image(systemName: "arrow.up.doc") }
                .help("Upload files or folders")
                .a11yButton("Upload files or folders")
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .a11yButton("New folder")
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
                .a11yButton("Refresh")
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading folder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .accessibilityLabel("Server browser toolbar")
    }

    /// Clickable path segments — jump up any number of levels in one click.
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                            // A separator between path segments, not a control.
                            .a11yDecorative()
                    }
                    let isLast = idx == breadcrumbs.count - 1
                    Button { if !isLast { Task { await model.go(toPath: crumb.path) } } } label: {
                        Text(crumb.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isLast ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain).disabled(isLast)
                    // Which crumb is the *current* folder is shown only by a
                    // darker text colour — colour alone, and inaudible.
                    .accessibilityLabel(isLast ? "Current folder, \(crumb.label)"
                                               : "Go to \(crumb.label)")
                }
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    /// Sort key + direction, plus the hidden-files toggle.
    private var sortMenu: some View {
        Menu {
            Button(sortItemLabel("Name", "name")) { setSort("name") }
            Button(sortItemLabel("Size", "size")) { setSort("size") }
            Button(sortItemLabel("Date Modified", "modified")) { setSort("modified") }
            Divider()
            Toggle("Show Hidden Files", isOn: $showHidden)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Sort & display options")
        // The menu's own items use "↑"/"↓" suffixes to mark the active key, so
        // the current sort is stated here rather than left to those arrows.
        .accessibilityLabel("Sort and display options")
        .accessibilityValue("\(sortKeyRaw), \(sortAscending ? "ascending" : "descending")")
    }

    private func sortItemLabel(_ title: String, _ key: String) -> String {
        guard sortKeyRaw == key else { return title }
        return "\(title)  \(sortAscending ? "↑" : "↓")"
    }

    private struct Crumb { let label: String; let path: String }

    private var breadcrumbs: [Crumb] {
        let path = model.path
        if path == "." || path.isEmpty { return [Crumb(label: "Home", path: ".")] }
        if path == "/" { return [Crumb(label: "/", path: "/")] }
        if path.hasPrefix("/") {
            var crumbs = [Crumb(label: "/", path: "/")]
            var acc = ""
            for part in path.split(separator: "/", omittingEmptySubsequences: true) {
                acc += "/" + part
                crumbs.append(Crumb(label: String(part), path: acc))
            }
            return crumbs
        }
        var crumbs = [Crumb(label: "Home", path: ".")]   // relative to the login home
        var acc = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            crumbs.append(Crumb(label: String(part), path: acc))
        }
        return crumbs
    }

    // MARK: Search + entry list

    /// The display pipeline: hide dotfiles (unless toggled), apply the search
    /// filter, then sort per the chosen key/direction (folders always first).
    private var visibleEntries: [SFTPEntry] {
        var list = model.entries
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return list.sorted(by: sortComparator)
    }

    private func sortComparator(_ a: SFTPEntry, _ b: SFTPEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }   // folders first, always
        let ascending: Bool
        switch sortKeyRaw {
        case "size":
            ascending = a.size == b.size
                ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                : a.size < b.size
        case "modified":
            let ad = a.modified ?? .distantPast, bd = b.modified ?? .distantPast
            ascending = ad == bd
                ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                : ad < bd
        default:
            ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return sortAscending ? ascending : !ascending
    }

    private func setSort(_ key: String) {
        if sortKeyRaw == key { sortAscending.toggle() } else { sortKeyRaw = key; sortAscending = true }
    }

    /// A live filter over the current directory — entries are matched by name as
    /// you type; Enter jumps into a sole matching folder.
    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .a11yDecorative()
            TextField("Filter this folder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(openSoleSearchResult)
                .accessibilityLabel("Filter this folder")
                .accessibilityHint("Press return to open the only match.")
            if !searchText.isEmpty {
                Text("\(visibleEntries.count)")
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    // A bare number beside a filter field means nothing spoken.
                    .accessibilityLabel("\(visibleEntries.count) matches")
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter")
                .a11yButton("Clear filter")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    /// Enter in the filter jumps into the folder when it's the only match.
    private func openSoleSearchResult() {
        guard visibleEntries.count == 1, let only = visibleEntries.first, only.isDirectory else { return }
        Task { await model.open(only) }
    }

    // MARK: Selection & keyboard

    /// Click selection with modifiers: ⌘ toggles, ⇧ extends a range from the
    /// cursor, a plain click selects just this entry.
    private func handleClick(_ entry: SFTPEntry) {
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

    /// Double-click / Enter: open a folder, download a file.
    private func primaryAction(_ entry: SFTPEntry) {
        if entry.isDirectory { Task { await model.open(entry) } }
        else { downloadTargets([entry]) }
    }

    /// Keyboard driving: arrows move the cursor (⇧ extends, ⌘↓ opens, ⌘↑ up), Enter opens/downloads,
    /// Space previews, Delete removes, ⌘A selects all, Esc clears, letters jump to a matching name.
    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let entries = visibleEntries
        guard !entries.isEmpty else { return .ignored }
        let current = cursor.flatMap { id in entries.firstIndex { $0.id == id } }
        switch press.key {
        case .downArrow, .upArrow:
            // ⌘↓ / ⌘↑ navigate the hierarchy rather than the list, which is what
            // those chords do in Finder.
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
            selection.removeAll(); return .handled
        default:
            guard press.modifiers.contains(.command) else {
                // A bare printable character is a type-to-select query. Modifier
                // combinations and control keys fall through untouched.
                guard press.modifiers.subtracting(.shift).isEmpty,
                      let character = press.characters.first,
                      character.isLetter || character.isNumber
                        || character == "." || character == "-" || character == "_"
                else { return .ignored }
                return typeSelect(character, entries: entries, proxy: proxy)
            }
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
    }

    /// Finder's type-to-select: keystrokes within ``typeSelectWindow`` accumulate, so "re" reaches
    /// "report.pdf" past "readme"; after a pause a single letter cycles through matches.
    private func typeSelect(_ character: Character, entries: [SFTPEntry],
                            proxy: ScrollViewProxy) -> KeyPress.Result {
        let now = Date()
        let continuing = now.timeIntervalSince(typeSelectAt) < Self.typeSelectWindow
        typeSelectAt = now

        let repeated = continuing && typeSelectBuffer == String(character)
        typeSelectBuffer = continuing && !repeated ? typeSelectBuffer + String(character)
                                                  : String(character)

        // Repeating one letter cycles; extending the prefix restarts the search.
        let startIndex: Int
        if repeated, let c = cursor.flatMap({ id in entries.firstIndex { $0.id == id } }) {
            startIndex = c + 1
        } else {
            startIndex = 0
        }
        let prefix = typeSelectBuffer.lowercased()
        let order = (0..<entries.count).map { (startIndex + $0) % entries.count }
        guard let hit = order.first(where: { entries[$0].name.lowercased().hasPrefix(prefix) })
        else { return .handled }   // no match: swallow the key rather than act on it

        let id = entries[hit].id
        cursor = id
        selection = [id]
        proxy.scrollTo(id, anchor: .center)
        return .handled
    }

    /// Put the current selection — or the row under the cursor when nothing is
    /// selected — on the remote clipboard.
    private func copySelection(_ operation: SFTPClipboard.Operation) {
        let targets = clipboardTargets()
        guard !targets.isEmpty else { return }
        vm.copySFTPItems(targets, from: model.connection, directory: model.path,
                         operation: operation)
    }

    private func duplicateSelection() {
        let targets = clipboardTargets()
        guard !targets.isEmpty else { return }
        vm.duplicateSFTPItems(targets, on: model.connection, directory: model.path)
    }

    /// What ⌘C / ⌘X / ⌘D act on: the selection if there is one, otherwise the keyboard cursor's row,
    /// so the shortcuts work straight after arrow-keying to an item.
    private func clipboardTargets() -> [SFTPEntry] {
        let selected = visibleEntries.filter { selection.contains($0.id) }
        if !selected.isEmpty { return selected }
        return visibleEntries.filter { $0.id == cursor }
    }

    // MARK: Row actions

    /// The entries an action applies to: the whole selection when the clicked row
    /// is part of a multi-selection, otherwise just that row.
    private func actionTargets(for entry: SFTPEntry) -> [SFTPEntry] {
        if selection.contains(entry.id) && selection.count > 1 {
            return visibleEntries.filter { selection.contains($0.id) }
        }
        return [entry]
    }

    // MARK: Info panel

    /// Open the info panel for one entry, fetching its attributes and — for a
    /// folder — walking it for a real size.
    private func showInfo(_ entry: SFTPEntry) {
        closeInfo()
        infoEntry = entry
        Task { entryInfo = await model.info(for: entry) }
        guard entry.isDirectory else { return }
        let cancel = CancelFlag()
        infoSizeCancel = cancel
        infoSizeTask = Task {
            let size = await model.recursiveSize(of: entry,
                                                 shouldContinue: { !cancel.isCancelled })
            // A walk that was cancelled must not write its partial answer into a
            // panel that has since been closed or re-pointed.
            guard !cancel.isCancelled else { return }
            infoFolderSize = size
            infoSizeTask = nil
        }
    }

    private func closeInfo() {
        infoSizeCancel?.cancel()
        infoSizeTask?.cancel()
        infoSizeTask = nil
        infoSizeCancel = nil
        infoFolderSize = nil
        entryInfo = nil
        infoEntry = nil
    }

    private func applyPermissions(_ entry: SFTPEntry, _ mode: UInt32) {
        Task {
            if await model.setPermissions(entry, mode: mode) {
                vm.toastNow("Permissions updated")
                entryInfo = await model.info(for: entry)
            }
        }
    }

    private func downloadsDir() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Download `entries` — files and whole folders alike — to the user's
    /// Downloads folder.
    private func downloadTargets(_ entries: [SFTPEntry]) {
        let items = entries.filter { SFTPBrowserPaths.isSafeChildName($0.name) }
        guard !items.isEmpty else { vm.toastNow("Select items to download"); return }
        let dir = downloadsDir()
        for item in items {
            vm.startDownload(item, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
        vm.toastNow(items.count == 1 ? "Downloading “\(items[0].name)” to Downloads"
                                     : "Downloading \(items.count) items to Downloads")
    }

    private func deleteTargets(_ entries: [SFTPEntry]) {
        guard entries.count > 1 else { pendingDelete = entries.first; return }
        vm.requestConfirm(
            title: "Delete \(entries.count) items?",
            message: "This permanently removes them from the server.",
            confirmTitle: "Delete", destructive: true
        ) {
            Task {
                // Counted, not assumed: a refusal mid-batch would otherwise be reported as a clean sweep, and
                // the next item's refresh clears the error banner that was the only other sign of it.
                var deleted = 0
                for e in entries where await model.delete(e) { deleted += 1 }
                selection.removeAll()
                if deleted == entries.count {
                    vm.toastNow("Deleted \(deleted) items")
                } else {
                    vm.toastNow("Deleted \(deleted) of \(entries.count) items — the rest couldn’t be removed.")
                }
            }
        }
    }

    /// The most a preview will pull to disk, applied both to the size the server
    /// advertised and to the bytes that actually arrive.
    private var previewByteCap: Int64 { 512 * 1024 * 1024 }

    /// Fetch a file to a temp copy, then peek it in the system Quick Look panel.
    private func quickLook(_ entry: SFTPEntry) {
        guard !entry.isDirectory, let client else { return }
        guard entry.size < previewByteCap else { vm.toastNow("Too large to preview"); return }
        let safe = PathSafety.sanitizedName(entry.name)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoelQL-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(safe)
        let remote = SFTPBrowserModel.join(model.path, entry.name)
        // `entry.size` is the server's claim, not a fact — a server reporting 0 would stream unbounded
        // data into the temp directory behind a preview. Bound the fetch itself.
        let cap = ByteCap(limit: previewByteCap)
        vm.toastNow("Preparing preview…")
        Task {
            do {
                try await client.downloadToFile(remote: remote, localURL: tmp,
                                                shouldContinue: { cap.underLimit }) { sofar, total in
                    cap.observe(sofar: sofar, total: total)
                }
                guard cap.underLimit else {
                    try? FileManager.default.removeItem(at: dir)
                    await MainActor.run { vm.toastNow("Too large to preview") }
                    return
                }
                await MainActor.run { QuickLookPresenter.shared.present(tmp) }
            } catch {
                // Tripping the cap aborts the transfer, so the throw arrives as a
                // bare "Aborted" — say what actually happened.
                try? FileManager.default.removeItem(at: dir)
                let message = cap.underLimit ? "Couldn’t preview “\(entry.name)”" : "Too large to preview"
                await MainActor.run { vm.toastNow(message) }
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        vm.toastNow("Copied")
    }

    private func remotePath(_ entry: SFTPEntry) -> String { SFTPBrowserModel.join(model.path, entry.name) }

    private func sftpURL(_ entry: SFTPEntry) -> String {
        let c = model.connection
        let p = remotePath(entry)
        return "sftp://\(c.username)@\(c.host):\(c.port)\(p.hasPrefix("/") ? p : "/" + p)"
    }

    /// A "Move to" submenu: the current folder's subfolders (and the parent), for
    /// a remote-to-remote move.
    @ViewBuilder
    private func moveMenu(_ entry: SFTPEntry) -> some View {
        Menu("Move to") {
            if !model.isAtRoot {
                Button("⬆︎ Parent folder") {
                    Task {
                        if await model.move(entry, toDirectory: SFTPBrowserModel.parent(of: model.path)) {
                            vm.toastNow("Moved “\(entry.name)”")
                        }
                    }
                }
                Divider()
            }
            // `folder.name` is server-supplied and joined straight onto the remote path, so it gets the same
            // guard as a drop target: an entry named "../.." must not relocate the file outside the tree.
            let folders = model.entries.filter {
                $0.isDirectory && $0.id != entry.id && SFTPBrowserPaths.isSafeChildName($0.name)
            }
            if folders.isEmpty {
                Text("No subfolders")
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        Task {
                            if await model.move(entry, toDirectory: SFTPBrowserModel.join(model.path, folder.name)) {
                                vm.toastNow("Moved to “\(folder.name)”")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Status footer

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if !selection.isEmpty {
                Text("\(selection.count) selected").foregroundStyle(Theme.accent)
                Button("Clear") { selection.removeAll() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(itemSummary)
            }
            Spacer()
            let totalBytes = visibleEntries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            if totalBytes > 0 { Text(totalBytes.byteString).foregroundStyle(.secondary) }
            // Only shown when the server answered `statvfs@openssh.com`; a server
            // without it simply shows nothing rather than an error nobody can act on.
            if let space = volumeSpace, space.totalBytes > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(space.freeBytes.byteString) free")
                    .foregroundStyle(.secondary)
                    .help("\(space.usedBytes.byteString) of \(space.totalBytes.byteString) used on this volume")
            }
        }
        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private var itemSummary: String {
        let folders = visibleEntries.filter(\.isDirectory).count
        let files = visibleEntries.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    // MARK: Entry list

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isGrid { gridBody } else { listBody }
            }
            .overlay { if visibleEntries.isEmpty && !model.isLoading { emptyState } }
            // Suppress the whole-pane "upload here" hint while a folder is being
            // hovered, so that folder's own drop target reads clearly.
            .overlay { if dropTargeted && folderDropTarget == nil { dropHint } }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleUploadDrop(providers)
            }
            .contextMenu { emptyAreaMenu }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress { press in handleKey(press, proxy: proxy) }
        }
    }

    @ViewBuilder private var emptyAreaMenu: some View {
        Button("New Folder") { showNewFolder = true }
        Button("Upload…") { chooseUploadItems() }
        if let clip = vm.sftpClipboard, !clip.isEmpty {
            Button(clip.pasteLabel) {
                vm.pasteSFTPClipboard(into: model.connection, directory: model.path)
            }
            .disabled(!vm.canPasteSFTP(into: model.connection, directory: model.path))
        }
        Divider()
        Button(showHidden ? "Hide Hidden Files" : "Show Hidden Files") { showHidden.toggle() }
        if !selection.isEmpty { Button("Deselect All") { selection.removeAll() } }
    }

    private var listBody: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(visibleEntries) { entry in
                    row(entry).id(entry.id)
                    Divider().opacity(0.35)
                }
            } header: {
                columnHeaders
            }
        }
    }

    /// Finder's clickable column headers: click to sort, click again to reverse. The widths mirror
    /// ``row(_:)`` exactly, so the headings sit over the values they name.
    private var columnHeaders: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18)
            sortHeader("Name", key: "name")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Size", key: "size")
                .frame(width: 72, alignment: .trailing)
            sortHeader("Date Modified", key: "modified")
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort by column")
    }

    private func sortHeader(_ title: String, key: String) -> some View {
        Button { setSort(key) } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold))
                // The active column is marked by its arrow, not by colour alone.
                if sortKeyRaw == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(sortKeyRaw == key ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sortKeyRaw == key
            ? "\(title), sorted \(sortAscending ? "ascending" : "descending")"
            : "Sort by \(title)")
        .accessibilityHint(sortKeyRaw == key ? "Activate to reverse the order."
                                             : "Activate to sort by this column.")
    }

    private var gridBody: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 12)],
                  spacing: 12) {
            ForEach(visibleEntries) { entry in
                gridTile(entry).id(entry.id)
            }
        }
        .padding(14)
    }

    /// "Folder, Documents" / "File, report.pdf" — the kind said in words, since
    /// visually it is only an SF Symbol and a tint.
    private func entryLabel(_ entry: SFTPEntry) -> String {
        let kind = entry.isSymlink
            ? (entry.isDirectory ? "Alias to folder" : "Alias")
            : (entry.isDirectory ? "Folder" : "File")
        return "\(kind), \(entry.name)"
    }

    /// The small arrow marking a symbolic link, with its target in the tooltip.
    private func symlinkBadge(_ entry: SFTPEntry) -> some View {
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .help(entry.linkTarget.isEmpty ? "Symbolic link"
                                           : "Symbolic link to \(entry.linkTarget)")
            // The name already says which row this is; the badge repeating
            // "alias" would double up with `entryLabel`.
            .a11yDecorative()
    }

    /// Size and modification date, spoken. Folders have no meaningful size, so
    /// they report only their date rather than a misleading zero.
    private func entryValue(_ entry: SFTPEntry) -> String {
        A11y.sentence(
            entry.isDirectory ? nil : A11y.bytes(entry.size),
            entry.modified.map { "modified \($0.formatted(date: .abbreviated, time: .shortened))" })
    }

    private func row(_ entry: SFTPEntry) -> some View {
        let hovered = hoveredEntry == entry.id
        let dropping = folderDropTarget == entry.id
        let selected = selection.contains(entry.id)
        return HStack(spacing: 10) {
            Image(systemName: SFTPFileIcon.symbol(for: entry))
                .foregroundStyle(SFTPFileIcon.tint(for: entry))
                .frame(width: 18)
            // Column widths here are mirrored by `columnHeaders`; changing one
            // without the other visibly de-registers the headings.
            HStack(spacing: 6) {
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                // A link looks exactly like what it points at otherwise, and the
                // difference matters: deleting one removes only the link.
                if entry.isSymlink { symlinkBadge(entry) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "—" : entry.size.byteString)
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(entry.isDirectory ? .tertiary : .secondary)
                .frame(width: 72, alignment: .trailing)
            Text(entry.modified.map { $0.formatted(.dateTime.year().month().day()) } ?? "—")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(entryHighlight(hovered: hovered, dropping: dropping, selected: selected))
        // Icon, name, size and date read as four fragments, and folder-ness is carried only by symbol
        // and tint. One element, and say "Folder" or "File" out loud.
        .a11yGroup(label: entryLabel(entry), value: entryValue(entry),
                   hint: entry.isDirectory ? "Activate to open." : "Activate to select.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { primaryAction(entry) }
        .contentShape(Rectangle())
        .onHover { inside in updateHover(entry.id, inside: inside) }
        .onTapGesture(count: 2) { primaryAction(entry) }
        .onTapGesture { handleClick(entry) }
        // Drag a remote file out to Finder (downloads on demand).
        .ifLet(entry.isDirectory ? nil : entry) { view, file in
            view.onDrag { model.fileProvider(for: file) }
        }
        // Drop local files onto a folder row to upload straight into it.
        .ifLet(entry.isDirectory ? entry : nil) { view, folder in
            view.onDrop(of: [.fileURL], isTargeted: folderDropBinding(folder.id)) { providers in
                handleUploadDrop(providers, into: folder)
            }
        }
        .contextMenu { rowMenu(entry) }
    }

    /// A file/folder tile for the grid layout — same behaviours as ``row`` (open,
    /// drag-out, drop-into, context menu) with hover + drop highlighting.
    private func gridTile(_ entry: SFTPEntry) -> some View {
        let hovered = hoveredEntry == entry.id
        let dropping = folderDropTarget == entry.id
        let selected = selection.contains(entry.id)
        return VStack(spacing: 7) {
            Image(systemName: SFTPFileIcon.symbol(for: entry))
                .font(.system(size: 32))
                .foregroundStyle(SFTPFileIcon.tint(for: entry))
                .frame(height: 38)
            Text(entry.name)
                .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(entry.isDirectory ? "Folder" : entry.size.byteString)
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 118)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropping ? Theme.accent.opacity(0.16)
                      : selected ? Theme.accent.opacity(0.20)
                      : hovered ? Color.primary.opacity(0.06)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropping || selected ? Theme.accent
                              : hovered ? Color.primary.opacity(0.12) : Color.clear,
                              lineWidth: (dropping || selected) ? 2 : 1)
        )
        // Same collapse as the list row — a grid tile is one item, and selection
        // here is signalled purely by an accent fill and border.
        .a11yGroup(label: entryLabel(entry), value: entryValue(entry),
                   hint: entry.isDirectory ? "Activate to open." : "Activate to select.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { primaryAction(entry) }
        .contentShape(Rectangle())
        .onHover { inside in updateHover(entry.id, inside: inside) }
        .onTapGesture(count: 2) { primaryAction(entry) }
        .onTapGesture { handleClick(entry) }
        .ifLet(entry.isDirectory ? nil : entry) { view, file in
            view.onDrag { model.fileProvider(for: file) }
        }
        .ifLet(entry.isDirectory ? entry : nil) { view, folder in
            view.onDrop(of: [.fileURL], isTargeted: folderDropBinding(folder.id)) { providers in
                handleUploadDrop(providers, into: folder)
            }
        }
        .contextMenu { rowMenu(entry) }
    }

    /// The hover / drop-target / selection fill shared by list rows.
    @ViewBuilder
    private func entryHighlight(hovered: Bool, dropping: Bool, selected: Bool) -> some View {
        if dropping {
            Theme.accent.opacity(0.16)
        } else if selected {
            Theme.accent.opacity(0.22)
        } else if hovered {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    /// Track the hovered entry, only clearing when the pointer leaves the row that
    /// currently owns the highlight (avoids a leave-event race between neighbours).
    private func updateHover(_ id: SFTPEntry.ID, inside: Bool) {
        if inside { hoveredEntry = id }
        else if hoveredEntry == id { hoveredEntry = nil }
    }

    /// A per-folder `isTargeted` binding that records which folder is being dragged
    /// onto — drives the highlight and suppresses the whole-pane hint.
    private func folderDropBinding(_ id: SFTPEntry.ID) -> Binding<Bool> {
        Binding(
            get: { folderDropTarget == id },
            set: { folderDropTarget = $0 ? id : (folderDropTarget == id ? nil : folderDropTarget) }
        )
    }

    @ViewBuilder
    private func rowMenu(_ entry: SFTPEntry) -> some View {
        let targets = actionTargets(for: entry)
        if targets.count > 1 {
            Button("Download \(targets.count) Items") { downloadTargets(targets) }
            Divider()
            clipboardMenuItems(targets)
            Divider()
            Button("Delete \(targets.count) Items", role: .destructive) { deleteTargets(targets) }
        } else {
            if entry.isDirectory {
                Button("Open") { Task { await model.open(entry) } }
                Divider()
                Button("Download Folder to Downloads") { downloadTargets([entry]) }
                Button("Download Folder to…") { chooseDownloadFolder(for: entry) }
            } else {
                Button("Download to Downloads") { downloadTargets([entry]) }
                Button("Download to…") { chooseDownloadFolder(for: entry) }
                Button("Add to Download Queue") {
                    vm.enqueueSFTPDownload(connection: model.connection, remotePath: remotePath(entry))
                }
                Button("Quick Look") { quickLook(entry) }
            }
            Divider()
            Button("Get Info") { showInfo(entry) }
            clipboardMenuItems([entry])
            Divider()
            Button("Rename…") { renaming = entry; renameText = entry.name }
            moveMenu(entry)
            Button("Copy Path") { copyToPasteboard(remotePath(entry)) }
            Button("Copy sftp:// Link") { copyToPasteboard(sftpURL(entry)) }
            Divider()
            Button("Delete", role: .destructive) { deleteTargets([entry]) }
        }
    }

    /// Copy / Cut / Duplicate / Paste, shared by the single- and multi-selection menus. Paste appears
    /// here as well as in the empty-area menu because right-clicking a row is how most people reach it.
    @ViewBuilder
    private func clipboardMenuItems(_ targets: [SFTPEntry]) -> some View {
        Button(targets.count == 1 ? "Copy" : "Copy \(targets.count) Items") {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path,
                             operation: .copy)
        }
        Button(targets.count == 1 ? "Cut" : "Cut \(targets.count) Items") {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path,
                             operation: .cut)
        }
        Button(targets.count == 1 ? "Duplicate" : "Duplicate \(targets.count) Items") {
            vm.duplicateSFTPItems(targets, on: model.connection, directory: model.path)
        }
        if let clip = vm.sftpClipboard, !clip.isEmpty {
            Button(clip.pasteLabel) {
                vm.pasteSFTPClipboard(into: model.connection, directory: model.path)
            }
            .disabled(!vm.canPasteSFTP(into: model.connection, directory: model.path))
        }
    }

    private var emptyState: some View {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return EmptyStateView(
            systemImage: searching ? "magnifyingglass" : "tray",
            title: searching ? "No matches" : "This folder is empty",
            subtitle: searching ? "Nothing here matches “\(searchText)”."
                                : "Drop files or folders here to upload",
            symbolSize: 30, symbolStyle: .tertiary)
    }

    private var dropHint: some View {
        ZStack {
            Theme.accent.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc").font(.system(size: 30))
                Text("Upload to \(model.displayPath)").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .allowsHitTesting(false)
        // Shown only mid-drag, a state that requires a pointer to reach.
        .a11yDecorative()
    }

    // MARK: Transfer strip

    private func consumeNavigationRequest(_ request: SFTPBrowserNavigationRequest?) async {
        guard let request, request.connectionID == model.connection.id else { return }
        _ = await model.go(toPath: request.path)
        vm.acknowledgeSFTPBrowserNavigation(request.id)
    }

    private func transferStrip(_ transfers: [SFTPTransfer]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if transfers.contains(where: { !$0.isActive }) {
                    Button("Clear") { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Clear finished transfers")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            ScrollView {
                ForEach(transfers) { t in
                    SFTPTransferRow(
                        transfer: t, density: .full,
                        onCancel: { vm.requestCancelSFTPTransfer(t.id) },
                        onRetry: { vm.retrySFTPTransfer(t.id) },
                        onShowRemoteFolder: { vm.revealSFTPTransfer(t) })
                }
            }
        }
        .padding(.bottom, 6)
        .background(.regularMaterial)
        .frame(maxHeight: 180)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                .a11yDecorative()
            Text(message).font(.system(size: 12)).lineLimit(2)
                // Triangle + orange wash are the only "this is an error" cues.
                .accessibilityLabel("Error. \(message)")
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .a11yButton("Dismiss error")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
        // The banner appears without taking focus, so nothing would otherwise
        // tell a screen-reader user that the operation they just ran failed.
        .onAppear { A11yAnnouncer.announce("Error. \(message)") }
    }

    // MARK: Drop / save handling

    private func handleUploadDrop(_ providers: [NSItemProvider]) -> Bool {
        let connection = model.connection
        let remoteDir = model.path
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            // Files and folders both upload (folders recurse in the transfer center).
            if !urls.isEmpty { vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection) }
        }
    }

    /// Drop straight onto a folder row/tile: upload into *that* folder rather than
    /// the open directory.
    private func handleUploadDrop(_ providers: [NSItemProvider], into folder: SFTPEntry) -> Bool {
        // `folder.name` comes from the server's listing — untrusted. Refuse any separator or traversal so
        // a hostile listing can't steer an upload outside the browsed directory; hidden names stay allowed.
        guard SFTPBrowserPaths.isSafeChildName(folder.name) else {
            vm.toastNow("Can’t upload into “\(folder.name)”")
            return false
        }
        let connection = model.connection
        let remoteDir = SFTPBrowserModel.join(model.path, folder.name)
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            if !urls.isEmpty {
                vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection)
                vm.toastNow("Uploading to “\(folder.name)”")
            }
        }
    }

    /// Pick local files and/or folders to upload into the current directory.
    private func chooseUploadItems() {
        let urls = FilePicker.openItems(
            canChooseFiles: true, canChooseDirectories: true,
            prompt: "Upload",
            message: "Choose files or folders to upload to \(model.displayPath)")
        if !urls.isEmpty {
            vm.startUpload(items: urls, toRemoteDir: model.path, on: model.connection)
        }
    }

    private func chooseDownloadFolder(for entry: SFTPEntry) {
        if let dir = FilePicker.chooseDirectory(
            prompt: "Download Here",
            message: "Choose where to save “\(entry.name)”") {
            vm.startDownload(entry, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
    }
}

/// Conditionally apply a modifier when an optional value is present.
private extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value { transform(self, value) } else { self }
    }
}
