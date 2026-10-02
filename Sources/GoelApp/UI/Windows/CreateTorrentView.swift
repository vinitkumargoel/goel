import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// Make a .torrent from a local file or folder: drop or choose the source, review trackers, web
/// seeds and piece size, then watch the hashing. It can start seeding as soon as it is written.
struct CreateTorrentView: View {
    let onClose: () -> Void
    @EnvironmentObject private var vm: AppViewModel
    @State private var sourcePath: String
    @State private var summary: TorrentSourceSummary?
    @State private var trackers: String
    @State private var webSeeds = ""
    @State private var pieceSize = 0
    @State private var isPrivate = false
    @State private var comment: String
    @State private var startSeeding = true
    @State private var progress: Double?
    @State private var cancelFlag = CancelFlag()
    @State private var error: String?
    @State private var dropTargeted = false
    @FocusState private var trackersFocused: Bool

    /// The extra parameters fill the form for previews and snapshots; the app passes only `onClose`.
    init(onClose: @escaping () -> Void, sourcePath: String = "", summary: TorrentSourceSummary? = nil,
         trackers: String = "", comment: String = "", progress: Double? = nil, error: String? = nil) {
        self.onClose = onClose
        _sourcePath = State(initialValue: sourcePath)
        _summary = State(initialValue: summary)
        _trackers = State(initialValue: trackers)
        _comment = State(initialValue: comment)
        _progress = State(initialValue: progress)
        _error = State(initialValue: error)
    }

    var body: some View {
        StudioSheet(title: L10n.t("Create Torrent"),
                    subtitle: L10n.t("Share a file or folder: hashing runs here, so the list stays free."),
                    symbol: "shippingbox", width: 580) {
            if let progress {
                hashing(progress)
            } else {
                source
                form
                if let error {
                    StudioNote(tone: .bad, symbol: "exclamationmark.triangle", message: error)
                }
            }
        } footer: {
            if progress == nil {
                StudioSheetFooter(cancelTitle: L10n.t("Close"), onCancel: onClose, primaryTitle: L10n.t("Create…"),
                                  primaryEnabled: !sourcePath.isEmpty, onPrimary: create) { EmptyView() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard progress == nil else { return false }
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                Task { @MainActor in sourcePath = path }
            }
            return true
        }
        .task(id: sourcePath) {
            guard !sourcePath.isEmpty else { summary = nil; return }
            if let loaded = await TorrentSourceSummary.load(sourcePath) { summary = loaded }
        }
    }

    // MARK: Source

    @ViewBuilder
    private var source: some View {
        if sourcePath.isEmpty {
            WindowsDropZone(isTargeted: dropTargeted, minHeight: 120) {
                Image(systemName: "folder")
                    .font(StudioFonts.font(.ui, size: 24, weight: 600))
                    .accessibilityHidden(true)
                Text(L10n.t("Drop a file or folder here"))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                chooseButtons
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Source file or folder"))
        } else {
            WindowsCompactCard(isSelected: dropTargeted, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
                StudioFileArtwork(kind: summary?.isFolder == false ? .other : .folder, size: .l)
                VStack(alignment: .leading, spacing: 2) {
                    Text((sourcePath as NSString).lastPathComponent)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(summary?.text ?? (sourcePath as NSString).abbreviatingWithTildeInPath)
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .help((sourcePath as NSString).abbreviatingWithTildeInPath)
                Menu(L10n.t("Change…")) {
                    Button(L10n.t("Choose File…")) { choose(directories: false) }
                    Button(L10n.t("Choose Folder…")) { choose(directories: true) }
                }
                .menuStyle(.button)
                .buttonStyle(.studio(.ghost, size: .small))
                .fixedSize()
                .accessibilityLabel(L10n.t("Change source"))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Source file or folder"))
        }
    }

    private var chooseButtons: some View {
        HStack(spacing: Studio.Space.s) {
            Button(L10n.t("Choose File…")) { choose(directories: false) }
            Button(L10n.t("Choose Folder…")) { choose(directories: true) }
        }
        .buttonStyle(.studio(.secondary, size: .small))
    }

    // MARK: Options

    private var form: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            WindowsLabeledField(label: L10n.t("Trackers"), help: L10n.t("One per line. Leave empty for a trackerless torrent (DHT).")) {
                TextEditor(text: $trackers)
                    .studioFont(.monoBody)
                    .foregroundStyle(Studio.Palette.ink)
                    .scrollContentBackground(.hidden)
                    .focused($trackersFocused)
                    .padding(.horizontal, Studio.Space.s)
                    .padding(.vertical, Studio.Space.xs)
                    .frame(height: 74)
                    .modifier(StudioFieldChrome(isFocused: trackersFocused, radius: Studio.Radius.small))
                    .accessibilityLabel(L10n.t("Tracker URLs, one per line"))
            }
            WindowsLabeledField(label: L10n.t("Web seeds")) {
                textField(L10n.t("Optional — https:// mirrors"), text: $webSeeds, mono: true, label: L10n.t("Web seeds"))
            }
            HStack(alignment: .top, spacing: Studio.Space.m) {
                WindowsLabeledField(label: L10n.t("Piece size")) { pieceSizeMenu }
                WindowsLabeledField(label: L10n.t("Comment")) {
                    textField(L10n.t("Optional"), text: $comment, mono: false, label: L10n.t("Comment"))
                }
            }
            HStack(spacing: Studio.Space.xl) {
                Toggle(L10n.t("Private"), isOn: $isPrivate)
                    .help(L10n.t("Peers come only from the trackers: no DHT, PeX or local discovery."))
                Toggle(L10n.t("Start seeding"), isOn: $startSeeding)
                Spacer(minLength: 0)
            }
            .toggleStyle(.studioCheckbox)
            .studioFont(.small)
        }
    }

    private func textField(_ prompt: String, text: Binding<String>, mono: Bool, label: String) -> some View {
        StudioFocusedField(size: .small) { focus in
            TextField(text: text, prompt: Text(prompt).foregroundStyle(Studio.Palette.ink3)) { Text(prompt) }
                .textFieldStyle(.plain)
                .focused(focus)
                .studioFont(mono ? .monoBody : .body.size(12.5))
                .accessibilityLabel(label)
        }
    }

    private var pieceSizeMenu: some View {
        Dropdown(selection: $pieceSize,
                 items: TorrentCreator.pieceSizes.map { .option($0, Self.pieceLabel($0)) },
                 accessibilityName: L10n.t("Piece size"))
    }

    static func pieceLabel(_ size: Int) -> String {
        size == 0 ? L10n.t("Auto") : Int64(size).byteString
    }

    // MARK: Hashing

    private func hashing(_ progress: Double) -> some View {
        let percent = Int(progress * 100)
        return VStack(spacing: Studio.Space.m) {
            StudioProgressArc(fraction: progress, diameter: 104, lineWidth: 8,
                              accessibilityLabel: L10n.t("Hashing pieces")) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: "\(percent)")
                        .studioFont(.display, size: 30, weight: 750, tabularNumbers: true)
                    Text(verbatim: "%")
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink3)
                }
                .foregroundStyle(Studio.Palette.ink)
            }
            Text(L10n.t("Hashing pieces…"))
                .studioFont(.title3)
                .foregroundStyle(Studio.Palette.ink)
            Text((sourcePath as NSString).lastPathComponent)
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L10n.t("Stop"), systemImage: "stop.fill") { cancelFlag.cancel() }
                .buttonStyle(.studio(.secondary, size: .small))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.t("Stop hashing"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Studio.Space.xl)
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

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
