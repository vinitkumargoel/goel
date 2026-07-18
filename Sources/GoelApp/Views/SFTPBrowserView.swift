import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// The main-pane SFTP file browser, shown in place of the download list when a
/// server is selected in the sidebar. Drop files from Finder to upload; drag a
/// remote file out to download it (or use the context menu). Files can also be
/// handed to the normal download queue.
struct SFTPBrowserView: View {
    @EnvironmentObject private var vm: AppViewModel
    @StateObject private var model: SFTPBrowserModel

    /// The connection/client as most recently handed down by the parent. Stored
    /// as plain view properties (not `@StateObject`) so they always reflect the
    /// latest edit; `.onChange` forwards them into the long-lived model, which
    /// SwiftUI keeps alive across an edit because the connection `id` is stable.
    private let connection: SFTPConnection
    private let client: SFTPClient?

    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SFTPEntry?

    /// The entry currently under the pointer, for the hover highlight (list + grid).
    @State private var hoveredEntry: SFTPEntry.ID?
    /// The folder currently being dragged *onto*, so a drop uploads *into* it
    /// rather than the open directory. One id at a time (the pointer is over one
    /// folder), which also suppresses the whole-pane drop hint.
    @State private var folderDropTarget: SFTPEntry.ID?
    /// List vs. grid layout, remembered across launches.
    @AppStorage("sftp.browser.gridView") private var isGrid = false

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
            entryList
            let myTransfers = vm.sftpTransfers(for: model.connection.id)
            if !myTransfers.isEmpty {
                Divider()
                transferStrip(myTransfers)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.connection.id) {
            await model.refresh()
            // Piggy-back OS detection on this already-authenticated session, so it
            // never opens a connection of its own to an un-browsed server.
            vm.detectServerOSIfNeeded(connection, client: client)
        }
        // When the connection is edited (host/username/port/password), the parent
        // re-renders this view with the fresh value but the @StateObject model is
        // kept alive — so forward the new credentials in and re-list, otherwise the
        // open browser keeps using the pre-edit login.
        .onChange(of: connection) {
            model.update(connection: connection, client: client)
            Task { await model.refresh() }
        }
        // Re-list when a transfer changes the current server's contents (e.g. an
        // upload finishes) — the transfer center bumps this on completion.
        .onChange(of: vm.sftpMutationTick) { Task { await model.refresh() } }
        // Clear any stale hover/drop highlight when the listing changes — SFTPEntry
        // ids are just names, so a same-named entry in the new folder must not
        // inherit the previous folder's highlight until the pointer next moves.
        .onChange(of: model.path) { hoveredEntry = nil; folderDropTarget = nil }
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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { vm.closeServerBrowser() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to downloads")

            Image(systemName: "lock.rectangle.on.rectangle").foregroundStyle(Theme.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.connection.label).font(.system(size: 13, weight: .semibold))
                Text(model.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Picker("", selection: $isGrid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            .help("Switch between list and grid view")

            Button { Task { await model.goUp() } } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.isAtRoot)
            .help("Parent folder")

            Button { chooseUploadItems() } label: { Image(systemName: "arrow.up.doc") }
                .help("Upload files or folders")
            Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    // MARK: Entry list

    private var entryList: some View {
        ScrollView {
            if isGrid { gridBody } else { listBody }
        }
        .overlay { if model.entries.isEmpty && !model.isLoading { emptyState } }
        // Suppress the whole-pane "upload here" hint while a folder is being
        // hovered, so that folder's own drop target reads clearly.
        .overlay { if dropTargeted && folderDropTarget == nil { dropHint } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleUploadDrop(providers)
        }
    }

    private var listBody: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.entries) { entry in
                row(entry)
                Divider().opacity(0.35)
            }
        }
    }

    private var gridBody: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 12)],
                  spacing: 12) {
            ForEach(model.entries) { entry in
                gridTile(entry)
            }
        }
        .padding(14)
    }

    private func row(_ entry: SFTPEntry) -> some View {
        let hovered = hoveredEntry == entry.id
        let dropping = folderDropTarget == entry.id
        return HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
                .frame(width: 18)
            Text(entry.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if !entry.isDirectory {
                Text(entry.size.byteString)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let date = entry.modified {
                Text(date, format: .dateTime.year().month().day())
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(entryHighlight(hovered: hovered, dropping: dropping))
        .contentShape(Rectangle())
        .onHover { inside in updateHover(entry.id, inside: inside) }
        .onTapGesture(count: 2) {
            if entry.isDirectory { Task { await model.open(entry) } }
        }
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
        return VStack(spacing: 7) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
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
                      : hovered ? Color.primary.opacity(0.06)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropping ? Theme.accent
                              : hovered ? Color.primary.opacity(0.12) : Color.clear,
                              lineWidth: dropping ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onHover { inside in updateHover(entry.id, inside: inside) }
        .onTapGesture(count: 2) {
            if entry.isDirectory { Task { await model.open(entry) } }
        }
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

    /// The hover / drop-target fill shared by list rows.
    @ViewBuilder
    private func entryHighlight(hovered: Bool, dropping: Bool) -> some View {
        if dropping {
            Theme.accent.opacity(0.16)
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
        if entry.isDirectory {
            Button("Open") { Task { await model.open(entry) } }
        } else {
            Button("Download to…") { chooseDownloadFolder(for: entry) }
            Button("Add to Download Queue") {
                vm.enqueueSFTPDownload(connection: model.connection,
                                       remotePath: SFTPBrowserModel.join(model.path, entry.name))
            }
        }
        Divider()
        Button("Delete", role: .destructive) { pendingDelete = entry }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("This folder is empty").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Drop files or folders here to upload").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
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
    }

    // MARK: Transfer strip

    private func transferStrip(_ transfers: [SFTPTransfer]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                if transfers.contains(where: { !$0.isActive }) {
                    Button("Clear") { vm.clearFinishedSFTPTransfers() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            ScrollView {
                ForEach(transfers) { t in transferRow(t) }
            }
        }
        .padding(.bottom, 6)
        .background(.regularMaterial)
        .frame(maxHeight: 180)
    }

    @ViewBuilder
    private func transferRow(_ t: SFTPTransfer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: t.iconName(filledWhenFinished: true))
                    .foregroundStyle(t.tint)
                Text(t.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                switch t.state {
                case .failed(let message):
                    Text(message).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(1)
                    Button("Retry") { vm.retrySFTPTransfer(t.id) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                case .cancelled:
                    Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Retry") { vm.retrySFTPTransfer(t.id) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                case .finished:
                    Text(t.total > 0 ? "Done · \(t.total.byteString)" : "Done")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.green)
                case .running:
                    Text(t.progressLabel)
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                    Button { vm.requestCancelSFTPTransfer(t.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                }
            }
            // Full running statistics: progress bar, bytes done / total, live
            // speed (green download / teal upload), and ETA.
            if t.isActive {
                HStack(spacing: 10) {
                    ProgressView(value: t.fraction).frame(maxWidth: 160)
                    Text(t.sizeLabel)
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    if !t.speedLabel.isEmpty {
                        Label(t.speedLabel, systemImage: t.direction == .upload ? "arrow.up" : "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(t.direction == .upload ? Theme.teal : Theme.green)
                    }
                    if let eta = t.etaLabel {
                        Text(eta).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
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
        // `folder.name` comes from the server's directory listing — untrusted. Refuse
        // any separator or parent-traversal so a hostile listing can't steer an
        // upload outside the browsed directory. (Hidden ".config"-style names stay
        // allowed; only path structure is rejected.)
        guard !folder.name.contains("/"), folder.name != "..", folder.name != "." else {
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
