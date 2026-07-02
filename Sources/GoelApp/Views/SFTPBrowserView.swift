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

    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: SFTPEntry?

    init(connection: SFTPConnection, client: SFTPClient?) {
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
        .task(id: model.connection.id) { await model.refresh() }
        // Re-list when a transfer changes the current server's contents (e.g. an
        // upload finishes) — the transfer center bumps this on completion.
        .onChange(of: vm.sftpMutationTick) { Task { await model.refresh() } }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeDirectory(named: name) }
            }
        }
        .alert("Delete “\(pendingDelete?.name ?? "")”?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await model.delete(entry) } }
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
            LazyVStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    row(entry)
                    Divider().opacity(0.35)
                }
            }
        }
        .overlay { if model.entries.isEmpty && !model.isLoading { emptyState } }
        .overlay { if dropTargeted { dropHint } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleUploadDrop(providers)
        }
    }

    private func row(_ entry: SFTPEntry) -> some View {
        HStack(spacing: 10) {
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory { Task { await model.open(entry) } }
        }
        // Drag a remote file out to Finder (downloads on demand).
        .ifLet(entry.isDirectory ? nil : entry) { view, file in
            view.onDrag { model.fileProvider(for: file) }
        }
        .contextMenu { rowMenu(entry) }
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
        HStack(spacing: 8) {
            Image(systemName: icon(for: t))
                .foregroundStyle(tint(for: t))
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
                Text("Done").font(.system(size: 11)).foregroundStyle(Theme.green)
            case .running:
                ProgressView(value: t.fraction).frame(width: 110)
                Text(t.total > 0 ? "\(Int(t.fraction * 100))%" : t.bytes.byteString)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                Button { vm.cancelSFTPTransfer(t.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private func icon(for t: SFTPTransfer) -> String {
        let base = t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        return t.state == .finished ? base + ".fill" : base
    }

    private func tint(for t: SFTPTransfer) -> Color {
        switch t.state {
        case .failed: return Theme.red
        case .finished: return Theme.green
        case .cancelled: return .secondary
        case .running: return Theme.accent
        }
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
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        let connection = model.connection
        let remoteDir = model.path
        group.notify(queue: .main) {
            // Files and folders both upload (folders recurse in the transfer center).
            if !urls.isEmpty { vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection) }
        }
        return true
    }

    /// Pick local files and/or folders to upload into the current directory.
    private func chooseUploadItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(model.displayPath)"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            vm.startUpload(items: panel.urls, toRemoteDir: model.path, on: model.connection)
        }
    }

    private func chooseDownloadFolder(for entry: SFTPEntry) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Download Here"
        panel.message = "Choose where to save “\(entry.name)”"
        if panel.runModal() == .OK, let dir = panel.url {
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
