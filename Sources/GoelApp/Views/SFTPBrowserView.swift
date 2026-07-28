import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct SFTPBrowserView: View {
    @EnvironmentObject private var vm: AppViewModel
    @StateObject private var model: SFTPBrowserModel

    private let connection: SFTPConnection
    private let client: SFTPClient?

    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SFTPEntry?

    @State private var hoveredEntry: SFTPEntry.ID?
    @State private var folderDropTarget: SFTPEntry.ID?
    @AppStorage("sftp.browser.gridView") private var isGrid = false
    @State private var searchText = ""
    @State private var selection: Set<SFTPEntry.ID> = []
    @State private var cursor: SFTPEntry.ID?
    @FocusState private var listFocused: Bool
    @State private var renaming: SFTPEntry?
    @State private var renameText = ""
    @AppStorage("sftp.browser.sortKey") private var sortKeyRaw = "name"
    @AppStorage("sftp.browser.sortAsc") private var sortAscending = true
    @AppStorage("sftp.browser.showHidden") private var showHidden = false
    @State private var infoEntry: SFTPEntry?
    @State private var entryInfo: SFTPEntryInfo?
    @State private var infoFolderSize: Int64?
    @State private var infoSizeTask: Task<Void, Never>?
    @State private var infoSizeCancel: CancelFlag?
    @State private var typeSelectBuffer = ""
    @State private var typeSelectAt = Date.distantPast
    private static let typeSelectWindow: TimeInterval = 1.0
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
            // Reuses this authenticated session; never opens one to an un-browsed server.
            vm.detectServerOSIfNeeded(connection, client: client)
        }
        // The @StateObject model outlives the parent's re-render; without this it keeps the pre-edit login.
        .onChange(of: connection) {
            model.update(connection: connection, client: client)
            Task { await model.refresh() }
        }
        .onChange(of: vm.sftpMutationTick) { Task { await model.refresh() } }
        .onChange(of: vm.sftpBrowserNavigation) { _, request in
            Task { await consumeNavigationRequest(request) }
        }
        // SFTPEntry ids are just names: a same-named entry must not inherit the old highlight.
        .onChange(of: model.path) {
            hoveredEntry = nil; folderDropTarget = nil; searchText = ""
            selection.removeAll(); cursor = nil
            typeSelectBuffer = ""; typeSelectAt = .distantPast
            closeInfo()
        }
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
        .alert(L10n.t("New Folder"), isPresented: $showNewFolder) {
            TextField(L10n.t("Name"), text: $newFolderName)
            Button(L10n.t("Cancel"), role: .cancel) { newFolderName = "" }
            Button(L10n.t("Create")) {
                let name = newFolderName
                newFolderName = ""
                Task { if await model.makeDirectory(named: name) { vm.toastNow(L10n.t("Folder created")) } }
            }
        }
        .alert(L10n.t("Delete “%@”?", pendingDelete?.name ?? ""),
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.t("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("Delete"), role: .destructive) {
                if let entry = pendingDelete {
                    Task { if await model.delete(entry) { vm.toastNow(L10n.t("Deleted “%@”", entry.name)) } }
                }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.isDirectory == true
                 ? L10n.t("The folder must be empty.")
                 : L10n.t("This permanently removes the file from the server."))
        }
        .alert(L10n.t("Rename “%@”", renaming?.name ?? ""),
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField(L10n.t("Name"), text: $renameText)
            Button(L10n.t("Cancel"), role: .cancel) { renaming = nil }
            Button(L10n.t("Rename")) {
                if let entry = renaming {
                    let newName = renameText
                    Task { if await model.rename(entry, to: newName) { vm.toastNow(L10n.t("Renamed")) } }
                }
                renaming = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { vm.closeServerBrowser() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(L10n.t("Back to downloads"))
            .a11yButton(L10n.t("Back to downloads"))

            Button { Task { await model.goBack() } } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).help(L10n.t("Back"))
                .keyboardShortcut("[", modifiers: .command)
                .a11yButton(L10n.t("Back"))
            Button { Task { await model.goForward() } } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).help(L10n.t("Forward"))
                .keyboardShortcut("]", modifiers: .command)
                .a11yButton(L10n.t("Forward"))

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
                    .accessibilityLabel(L10n.t("List"))
                Image(systemName: "square.grid.2x2").tag(true)
                    .accessibilityLabel(L10n.t("Grid"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            .help(L10n.t("Switch between list and grid view"))
            .accessibilityLabel(L10n.t("View style"))

            sortMenu

            Button { Task { await model.goUp() } } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.isAtRoot)
            .help(L10n.t("Parent folder"))
            .keyboardShortcut(.upArrow, modifiers: .command)
            .a11yButton(L10n.t("Parent folder"))

            Button { chooseUploadItems() } label: { Image(systemName: "arrow.up.doc") }
                .help(L10n.t("Upload files or folders"))
                .a11yButton(L10n.t("Upload files or folders"))
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help(L10n.t("New folder"))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .a11yButton(L10n.t("New folder"))
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help(L10n.t("Refresh"))
                .keyboardShortcut("r", modifiers: .command)
                .a11yButton(L10n.t("Refresh"))
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.t("Loading folder"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .accessibilityLabel(L10n.t("Server browser toolbar"))
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                            .a11yDecorative()
                    }
                    let isLast = idx == breadcrumbs.count - 1
                    Button { if !isLast { Task { await model.go(toPath: crumb.path) } } } label: {
                        Text(crumb.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isLast ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain).disabled(isLast)
                    .accessibilityLabel(isLast ? L10n.t("Current folder, %@", crumb.label)
                                               : L10n.t("Go to %@", crumb.label))
                }
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Folder path"))
    }

    private var sortMenu: some View {
        Menu {
            Button(sortItemLabel(L10n.t("Name"), "name")) { setSort("name") }
            Button(sortItemLabel(L10n.t("Size"), "size")) { setSort("size") }
            Button(sortItemLabel(L10n.t("Date Modified"), "modified")) { setSort("modified") }
            Divider()
            Toggle(L10n.t("Show Hidden Files"), isOn: $showHidden)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help(L10n.t("Sort & display options"))
        .accessibilityLabel(L10n.t("Sort and display options"))
        .accessibilityValue("\(sortKeyRaw), \(sortAscending ? L10n.t("ascending") : L10n.t("descending"))")
    }

    private func sortItemLabel(_ title: String, _ key: String) -> String {
        guard sortKeyRaw == key else { return title }
        return "\(title)  \(sortAscending ? "↑" : "↓")"
    }

    private struct Crumb { let label: String; let path: String }

    private var breadcrumbs: [Crumb] {
        let path = model.path
        if path == "." || path.isEmpty { return [Crumb(label: L10n.t("Home"), path: ".")] }
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
        var crumbs = [Crumb(label: L10n.t("Home"), path: ".")]
        var acc = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            crumbs.append(Crumb(label: String(part), path: acc))
        }
        return crumbs
    }

    private var visibleEntries: [SFTPEntry] {
        var list = model.entries
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return list.sorted(by: sortComparator)
    }

    private func sortComparator(_ a: SFTPEntry, _ b: SFTPEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
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

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .a11yDecorative()
            TextField(L10n.t("Filter this folder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(openSoleSearchResult)
                .accessibilityLabel(L10n.t("Filter this folder"))
                .accessibilityHint(L10n.t("Press return to open the only match."))
            if !searchText.isEmpty {
                Text("\(visibleEntries.count)")
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.t("%d matches", visibleEntries.count))
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.t("Clear filter"))
                .a11yButton(L10n.t("Clear filter"))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func openSoleSearchResult() {
        guard visibleEntries.count == 1, let only = visibleEntries.first, only.isDirectory else { return }
        Task { await model.open(only) }
    }

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

    private func primaryAction(_ entry: SFTPEntry) {
        if entry.isDirectory { Task { await model.open(entry) } }
        else { downloadTargets([entry]) }
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let entries = visibleEntries
        guard !entries.isEmpty else { return .ignored }
        let current = cursor.flatMap { id in entries.firstIndex { $0.id == id } }
        switch press.key {
        case .downArrow, .upArrow:
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

    private func typeSelect(_ character: Character, entries: [SFTPEntry],
                            proxy: ScrollViewProxy) -> KeyPress.Result {
        let now = Date()
        let continuing = now.timeIntervalSince(typeSelectAt) < Self.typeSelectWindow
        typeSelectAt = now

        let repeated = continuing && typeSelectBuffer == String(character)
        typeSelectBuffer = continuing && !repeated ? typeSelectBuffer + String(character)
                                                  : String(character)

        let startIndex: Int
        if repeated, let c = cursor.flatMap({ id in entries.firstIndex { $0.id == id } }) {
            startIndex = c + 1
        } else {
            startIndex = 0
        }
        let prefix = typeSelectBuffer.lowercased()
        let order = (0..<entries.count).map { (startIndex + $0) % entries.count }
        guard let hit = order.first(where: { entries[$0].name.lowercased().hasPrefix(prefix) })
        else { return .handled }

        let id = entries[hit].id
        cursor = id
        selection = [id]
        proxy.scrollTo(id, anchor: .center)
        return .handled
    }

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

    private func clipboardTargets() -> [SFTPEntry] {
        let selected = visibleEntries.filter { selection.contains($0.id) }
        if !selected.isEmpty { return selected }
        return visibleEntries.filter { $0.id == cursor }
    }

    private func actionTargets(for entry: SFTPEntry) -> [SFTPEntry] {
        if selection.contains(entry.id) && selection.count > 1 {
            return visibleEntries.filter { selection.contains($0.id) }
        }
        return [entry]
    }

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
            // A cancelled walk must not write its partial answer into a closed panel.
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
                vm.toastNow(L10n.t("Permissions updated"))
                entryInfo = await model.info(for: entry)
            }
        }
    }

    private func downloadsDir() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func downloadTargets(_ entries: [SFTPEntry]) {
        let items = entries.filter { SFTPBrowserPaths.isSafeChildName($0.name) }
        guard !items.isEmpty else { vm.toastNow(L10n.t("Select items to download")); return }
        let dir = downloadsDir()
        for item in items {
            vm.startDownload(item, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
        vm.toastNow(items.count == 1 ? L10n.t("Downloading “%@” to Downloads", items[0].name)
                                     : L10n.t("Downloading %d items to Downloads", items.count))
    }

    private func deleteTargets(_ entries: [SFTPEntry]) {
        guard entries.count > 1 else { pendingDelete = entries.first; return }
        vm.requestConfirm(
            title: L10n.t("Delete %d items?", entries.count),
            message: L10n.t("This permanently removes them from the server."),
            confirmTitle: L10n.t("Delete"), destructive: true
        ) {
            Task {
                // Count them: an unreported refusal mid-batch reads as a clean sweep.
                var deleted = 0
                for e in entries where await model.delete(e) { deleted += 1 }
                selection.removeAll()
                if deleted == entries.count {
                    vm.toastNow(L10n.t("Deleted %d items", deleted))
                } else {
                    vm.toastNow(L10n.t("Deleted %1$d of %2$d items — the rest couldn’t be removed.", deleted, entries.count))
                }
            }
        }
    }

    private var previewByteCap: Int64 { 512 * 1024 * 1024 }

    private func quickLook(_ entry: SFTPEntry) {
        guard !entry.isDirectory, let client else { return }
        guard entry.size < previewByteCap else { vm.toastNow(L10n.t("Too large to preview")); return }
        let safe = PathSafety.sanitizedName(entry.name)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoelQL-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(safe)
        let remote = SFTPBrowserModel.join(model.path, entry.name)
        // `entry.size` is the server's claim: a reported 0 would stream unbounded data to temp.
        let cap = ByteCap(limit: previewByteCap)
        vm.toastNow(L10n.t("Preparing preview…"))
        Task {
            do {
                try await client.downloadToFile(remote: remote, localURL: tmp,
                                                shouldContinue: { cap.underLimit }) { sofar, total in
                    cap.observe(sofar: sofar, total: total)
                }
                guard cap.underLimit else {
                    try? FileManager.default.removeItem(at: dir)
                    await MainActor.run { vm.toastNow(L10n.t("Too large to preview")) }
                    return
                }
                await MainActor.run { QuickLookPresenter.shared.present(tmp) }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                let message = cap.underLimit ? L10n.t("Couldn’t preview “%@”", entry.name) : L10n.t("Too large to preview")
                await MainActor.run { vm.toastNow(message) }
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        vm.toastNow(L10n.t("Copied"))
    }

    private func remotePath(_ entry: SFTPEntry) -> String { SFTPBrowserModel.join(model.path, entry.name) }

    private func sftpURL(_ entry: SFTPEntry) -> String {
        let c = model.connection
        let p = remotePath(entry)
        return "sftp://\(c.username)@\(c.host):\(c.port)\(p.hasPrefix("/") ? p : "/" + p)"
    }

    @ViewBuilder
    private func moveMenu(_ entry: SFTPEntry) -> some View {
        Menu(L10n.t("Move to")) {
            if !model.isAtRoot {
                Button(L10n.t("⬆︎ Parent folder")) {
                    Task {
                        if await model.move(entry, toDirectory: SFTPBrowserModel.parent(of: model.path)) {
                            vm.toastNow(L10n.t("Moved “%@”", entry.name))
                        }
                    }
                }
                Divider()
            }
            // `folder.name` is server-supplied: an entry named "../.." must not escape the tree.
            let folders = model.entries.filter {
                $0.isDirectory && $0.id != entry.id && SFTPBrowserPaths.isSafeChildName($0.name)
            }
            if folders.isEmpty {
                Text(L10n.t("No subfolders"))
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        Task {
                            if await model.move(entry, toDirectory: SFTPBrowserModel.join(model.path, folder.name)) {
                                vm.toastNow(L10n.t("Moved to “%@”", folder.name))
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if !selection.isEmpty {
                Text(L10n.t("%d selected", selection.count)).foregroundStyle(Theme.accent)
                Button(L10n.t("Clear")) { selection.removeAll() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(itemSummary)
            }
            Spacer()
            let totalBytes = visibleEntries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            if totalBytes > 0 { Text(totalBytes.byteString).foregroundStyle(.secondary) }
            if let space = volumeSpace, space.totalBytes > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(L10n.t("%@ free", space.freeBytes.byteString))
                    .foregroundStyle(.secondary)
                    .help(L10n.t("%1$@ of %2$@ used on this volume", space.usedBytes.byteString, space.totalBytes.byteString))
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
        if folders > 0 { parts.append(folders == 1 ? L10n.t("%d folder", folders) : L10n.t("%d folders", folders)) }
        if files > 0 { parts.append(files == 1 ? L10n.t("%d file", files) : L10n.t("%d files", files)) }
        return parts.isEmpty ? L10n.t("Empty") : parts.joined(separator: " · ")
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isGrid { gridBody } else { listBody }
            }
            .overlay { if visibleEntries.isEmpty && !model.isLoading { emptyState } }
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
        Button(L10n.t("New Folder")) { showNewFolder = true }
        Button(L10n.t("Upload…")) { chooseUploadItems() }
        if let clip = vm.sftpClipboard, !clip.isEmpty {
            Button(clip.pasteLabel) {
                vm.pasteSFTPClipboard(into: model.connection, directory: model.path)
            }
            .disabled(!vm.canPasteSFTP(into: model.connection, directory: model.path))
        }
        Divider()
        Button(showHidden ? L10n.t("Hide Hidden Files") : L10n.t("Show Hidden Files")) { showHidden.toggle() }
        if !selection.isEmpty { Button(L10n.t("Deselect All")) { selection.removeAll() } }
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

    private var columnHeaders: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18)
            sortHeader(L10n.t("Name"), key: "name")
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(L10n.t("Size"), key: "size")
                .frame(width: 72, alignment: .trailing)
            sortHeader(L10n.t("Date Modified"), key: "modified")
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Sort by column"))
    }

    private func sortHeader(_ title: String, key: String) -> some View {
        Button { setSort(key) } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold))
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
            ? L10n.t("%1$@, sorted %2$@", title, sortAscending ? L10n.t("ascending") : L10n.t("descending"))
            : L10n.t("Sort by %@", title))
        .accessibilityHint(sortKeyRaw == key ? L10n.t("Activate to reverse the order.")
                                             : L10n.t("Activate to sort by this column."))
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

    private func entryLabel(_ entry: SFTPEntry) -> String {
        let kind = entry.isSymlink
            ? (entry.isDirectory ? L10n.t("Alias to folder") : L10n.t("Alias"))
            : (entry.isDirectory ? L10n.t("Folder") : L10n.t("File"))
        return L10n.t("%1$@, %2$@", kind, entry.name)
    }

    private func symlinkBadge(_ entry: SFTPEntry) -> some View {
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .help(entry.linkTarget.isEmpty ? L10n.t("Symbolic link")
                                           : L10n.t("Symbolic link to %@", entry.linkTarget))
            .a11yDecorative()
    }

    private func entryValue(_ entry: SFTPEntry) -> String {
        A11y.sentence(
            entry.isDirectory ? nil : A11y.bytes(entry.size),
            entry.modified.map { L10n.t("modified %@", $0.formatted(date: .abbreviated, time: .shortened)) })
    }

    private func row(_ entry: SFTPEntry) -> some View {
        let hovered = hoveredEntry == entry.id
        let dropping = folderDropTarget == entry.id
        let selected = selection.contains(entry.id)
        return HStack(spacing: 10) {
            Image(systemName: SFTPFileIcon.symbol(for: entry))
                .foregroundStyle(SFTPFileIcon.tint(for: entry))
                .frame(width: 18)
            // These column widths are mirrored in `columnHeaders`; change both together.
            HStack(spacing: 6) {
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
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
        .a11yGroup(label: entryLabel(entry), value: entryValue(entry),
                   hint: entry.isDirectory ? L10n.t("Activate to open.") : L10n.t("Activate to select."))
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
            Text(entry.isDirectory ? L10n.t("Folder") : entry.size.byteString)
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
        .a11yGroup(label: entryLabel(entry), value: entryValue(entry),
                   hint: entry.isDirectory ? L10n.t("Activate to open.") : L10n.t("Activate to select."))
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

    /// Clear only if this row still owns the highlight — neighbours race on leave events.
    private func updateHover(_ id: SFTPEntry.ID, inside: Bool) {
        if inside { hoveredEntry = id }
        else if hoveredEntry == id { hoveredEntry = nil }
    }

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
            Button(L10n.t("Download %d Items", targets.count)) { downloadTargets(targets) }
            Divider()
            clipboardMenuItems(targets)
            Divider()
            Button(L10n.t("Delete %d Items", targets.count), role: .destructive) { deleteTargets(targets) }
        } else {
            if entry.isDirectory {
                Button(L10n.t("Open")) { Task { await model.open(entry) } }
                Divider()
                Button(L10n.t("Download Folder to Downloads")) { downloadTargets([entry]) }
                Button(L10n.t("Download Folder to…")) { chooseDownloadFolder(for: entry) }
            } else {
                Button(L10n.t("Download to Downloads")) { downloadTargets([entry]) }
                Button(L10n.t("Download to…")) { chooseDownloadFolder(for: entry) }
                Button(L10n.t("Add to Download Queue")) {
                    vm.enqueueSFTPDownload(connection: model.connection, remotePath: remotePath(entry))
                }
                Button(L10n.t("Quick Look")) { quickLook(entry) }
            }
            Divider()
            Button(L10n.t("Get Info")) { showInfo(entry) }
            clipboardMenuItems([entry])
            Divider()
            Button(L10n.t("Rename…")) { renaming = entry; renameText = entry.name }
            moveMenu(entry)
            Button(L10n.t("Copy Path")) { copyToPasteboard(remotePath(entry)) }
            Button(L10n.t("Copy sftp:// Link")) { copyToPasteboard(sftpURL(entry)) }
            Divider()
            Button(L10n.t("Delete"), role: .destructive) { deleteTargets([entry]) }
        }
    }

    @ViewBuilder
    private func clipboardMenuItems(_ targets: [SFTPEntry]) -> some View {
        Button(targets.count == 1 ? L10n.t("Copy") : L10n.t("Copy %d Items", targets.count)) {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path,
                             operation: .copy)
        }
        Button(targets.count == 1 ? L10n.t("Cut") : L10n.t("Cut %d Items", targets.count)) {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path,
                             operation: .cut)
        }
        Button(targets.count == 1 ? L10n.t("Duplicate") : L10n.t("Duplicate %d Items", targets.count)) {
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
            title: searching ? L10n.t("No matches") : L10n.t("This folder is empty"),
            subtitle: searching ? L10n.t("Nothing here matches “%@”.", searchText)
                                : L10n.t("Drop files or folders here to upload"),
            symbolSize: 30, symbolStyle: .tertiary)
    }

    private var dropHint: some View {
        ZStack {
            Theme.accent.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc").font(.system(size: 30))
                Text(L10n.t("Upload to %@", model.displayPath)).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .allowsHitTesting(false)
        .a11yDecorative()
    }

    private func consumeNavigationRequest(_ request: SFTPBrowserNavigationRequest?) async {
        guard let request, request.connectionID == model.connection.id else { return }
        _ = await model.go(toPath: request.path)
        vm.acknowledgeSFTPBrowserNavigation(request.id)
    }

    private func transferStrip(_ transfers: [SFTPTransfer]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Transfers")).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if transfers.contains(where: { !$0.isActive }) {
                    Button(L10n.t("Clear")) { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .accessibilityLabel(L10n.t("Clear finished transfers"))
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
                .accessibilityLabel(L10n.t("Error. %@", message))
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .a11yButton(L10n.t("Dismiss error"))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
        .onAppear { A11yAnnouncer.announce(L10n.t("Error. %@", message)) }
    }

    private func handleUploadDrop(_ providers: [NSItemProvider]) -> Bool {
        let connection = model.connection
        let remoteDir = model.path
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            if !urls.isEmpty { vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection) }
        }
    }

    private func handleUploadDrop(_ providers: [NSItemProvider], into folder: SFTPEntry) -> Bool {
        // `folder.name` is untrusted server listing data: refuse separators and traversal.
        guard SFTPBrowserPaths.isSafeChildName(folder.name) else {
            vm.toastNow(L10n.t("Can’t upload into “%@”", folder.name))
            return false
        }
        let connection = model.connection
        let remoteDir = SFTPBrowserModel.join(model.path, folder.name)
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            if !urls.isEmpty {
                vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection)
                vm.toastNow(L10n.t("Uploading to “%@”", folder.name))
            }
        }
    }

    private func chooseUploadItems() {
        let urls = FilePicker.openItems(
            canChooseFiles: true, canChooseDirectories: true,
            prompt: L10n.t("Upload"),
            message: L10n.t("Choose files or folders to upload to %@", model.displayPath))
        if !urls.isEmpty {
            vm.startUpload(items: urls, toRemoteDir: model.path, on: model.connection)
        }
    }

    private func chooseDownloadFolder(for entry: SFTPEntry) {
        if let dir = FilePicker.chooseDirectory(
            prompt: L10n.t("Download Here"),
            message: L10n.t("Choose where to save “%@”", entry.name)) {
            vm.startDownload(entry, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value { transform(self, value) } else { self }
    }
}
