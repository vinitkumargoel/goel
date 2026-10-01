import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// File ▸ Create Torrent…: its own window, so hashing a large folder never blocks the list.
@MainActor
final class CreateTorrentWindow {
    static let shared = CreateTorrentWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let vm = AppViewModel.shared else { return }
        let host = NSHostingController(rootView: CreateTorrentView(onClose: { [weak self] in self?.close() })
            .environmentObject(vm))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.t("Create Torrent")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct CreateTorrentView: View {
    let onClose: () -> Void
    @EnvironmentObject private var vm: AppViewModel
    @State private var sourcePath = ""
    @State private var trackers = ""
    @State private var webSeeds = ""
    @State private var pieceSize = 0
    @State private var isPrivate = false
    @State private var comment = ""
    @State private var startSeeding = true
    @State private var progress: Double?
    @State private var cancelFlag = CancelFlag()
    @State private var error: String?
    @State private var dropTargeted = false

    /// Read by the hashing thread; a class so the flag outlives the view's value copies.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            options
            if let error {
                Text(error).scaledFont(size: Theme.TextSize.meta).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                ProgressView(value: progress) {
                    Text(L10n.t("Hashing pieces… %d%%", Int(progress * 100)))
                        .scaledFont(size: Theme.TextSize.meta)
                }
            }
            footer
        }
        .padding(18)
        .frame(width: 480)
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: sourcePath.isEmpty ? "tray.and.arrow.down" : "doc.zipper")
                .scaledFont(size: 26).foregroundStyle(.secondary).a11yDecorative()
            Text(sourcePath.isEmpty ? L10n.t("Drop a file or folder here")
                                    : (sourcePath as NSString).abbreviatingWithTildeInPath)
                .scaledFont(size: Theme.TextSize.body).lineLimit(2).truncationMode(.middle)
            HStack {
                Button(L10n.t("Choose File…")) { choose(directories: false) }
                Button(L10n.t("Choose Folder…")) { choose(directories: true) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(dropTargeted ? Theme.accent : Color.secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 1.5, dash: [5])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                Task { @MainActor in sourcePath = path }
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Source file or folder"))
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow(alignment: .top) {
                label(L10n.t("Trackers"))
                TextEditor(text: $trackers)
                    .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel(L10n.t("Tracker URLs, one per line"))
            }
            GridRow {
                label(L10n.t("Web seeds"))
                TextField(L10n.t("Optional — https:// mirrors"), text: $webSeeds).textFieldStyle(.roundedBorder)
            }
            GridRow {
                label(L10n.t("Piece size"))
                Picker("", selection: $pieceSize) {
                    ForEach(TorrentCreator.pieceSizes, id: \.self) { size in
                        Text(size == 0 ? L10n.t("Auto") : Int64(size).byteString).tag(size)
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel(L10n.t("Piece size"))
            }
            GridRow {
                label(L10n.t("Comment"))
                TextField(L10n.t("Optional"), text: $comment).textFieldStyle(.roundedBorder)
            }
            GridRow {
                label(L10n.t("Options"))
                HStack(spacing: 14) {
                    Toggle(L10n.t("Private"), isOn: $isPrivate)
                        .help(L10n.t("Peers come only from the trackers: no DHT, PeX or local discovery."))
                    Toggle(L10n.t("Start seeding"), isOn: $startSeeding)
                }
            }
        }
        .disabled(progress != nil)
    }

    private func label(_ text: String) -> some View {
        Text(text).scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if progress != nil {
                Button(L10n.t("Stop")) { cancelFlag.cancel() }
            } else {
                Button(L10n.t("Close")) { onClose() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("Create…")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourcePath.isEmpty)
            }
        }
    }

    private func choose(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { sourcePath = url.path }
    }

    private func create() {
        // NSSavePanel asks "Replace?" itself before returning an existing file; nothing here
        // may bypass that (no delegate override), since the write below is an atomic replace.
        let save = NSSavePanel()
        save.canCreateDirectories = true
        save.isExtensionHidden = false
        save.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        let suggested = TorrentCreator.defaultOutputPath(for: sourcePath)
        save.nameFieldStringValue = (suggested as NSString).lastPathComponent
        save.directoryURL = URL(fileURLWithPath: (suggested as NSString).deletingLastPathComponent)
        guard save.runModal() == .OK, let out = save.url else { return }
        let options = TorrentCreator.Options(
            sourcePath: sourcePath, outputPath: out.path,
            trackers: TrackerList.parse(trackers),
            webSeeds: webSeeds.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," }).map(String.init),
            pieceSize: pieceSize, isPrivate: isPrivate, comment: comment)
        run(options)
    }

    private func run(_ options: TorrentCreator.Options) {
        error = nil
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag
        let seed = startSeeding
        Task {
            do {
                let url = try await TorrentCreator.create(options) { fraction in
                    Task { @MainActor in progress = fraction }
                    return !flag.isCancelled
                }
                progress = nil
                if seed { vm.seedCreatedTorrent(url, sourcePath: options.sourcePath) }
                vm.toastSuccess(L10n.t("Created “%@”", url.lastPathComponent))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                progress = nil
                if (error as? TorrentCreator.Failure) != .cancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

extension AppViewModel {
    /// Seeds a torrent just made from local data: saved beside the source, so libtorrent finds
    /// every piece already complete and goes straight to seeding.
    func seedCreatedTorrent(_ torrent: URL, sourcePath: String) {
        let folder = (sourcePath as NSString).deletingLastPathComponent
        let manager = self.manager
        Task { await manager.add(source: .torrentFile(torrent), saveDirectory: folder) }
    }
}
