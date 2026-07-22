import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The Add-download flow, in two steps:
///
///  1. **Input** — a drop zone + a URL / magnet / .m3u8 field (auto-pasted from
///     the clipboard when it holds a downloadable link). The button is
///     **Continue**, not "Add to queue".
///  2. **Confirm** — after resolving metadata, show the name, the size and (for
///     torrents) the file list, pick the destination folder (Downloads by
///     default) and priority, then **Start download** to actually queue it.
///
/// A multi-line batch skips the per-item preview and adds every line at once.
struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    /// Where we are in the two-step flow.
    private enum Phase: Equatable {
        case input
        case resolving
        case confirm(DownloadPreview)
    }
    @State private var phase: Phase = .input
    /// Torrent file indices the user unticked on the confirm screen (skip these).
    @State private var deselectedFileIDs: Set<Int> = []

    @State private var text: String = ""
    @State private var priority: FilePriority = .normal
    @State private var isDropTargeted = false
    /// Optional integrity hash; verified after a single HTTP/HLS download finishes.
    @State private var checksumText: String = ""
    /// Optional mirror URLs (one per line); segments fail over across them.
    @State private var mirrorsText: String = ""
    /// True while yt-dlp resolves a video-site page into its media stream.
    @State private var isResolvingMedia = false
    /// Inline validation shown under the input field.
    @State private var inputError: String?
    /// The in-flight metadata / yt-dlp resolution, so it can be cancelled.
    @State private var resolveTask: Task<Void, Never>?
    /// The fire-and-forget subtitle fetch, tracked so dismissing the sheet stops
    /// its yt-dlp subprocess instead of leaving it running.
    @State private var subtitleTask: Task<Void, Never>?

    /// When to start: "now", or a ``ScheduledStartOption`` preset id.
    @State private var startSelection: String = "now"

    /// The chosen "Save to" preset, shown on the confirm screen. Defaults to
    /// ~/Downloads per the requested behaviour.
    @State private var saveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    @State private var previousSaveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    /// A folder picked through the panel, surfaced as its own picker row.
    @State private var customFolder: String?

    /// Sentinel tags for the non-path picker rows.
    private enum SaveOption {
        static let automatic = "automatic"
        static let choose = "__choose__"
    }

    /// The saved server this download is forwarded to once it finishes — `ServerOption.none` for the ordinary local-only case.
    @State private var remoteSelection: String = ServerOption.none
    @State private var remoteDirectory: String = "."
    @State private var remoteRemoveLocal: Bool = false

    private enum ServerOption {
        static let none = "__local__"
    }

    private var downloadsPath: String { ("~/Downloads" as NSString).expandingTildeInPath }
    private var moviesPath: String { ("~/Movies" as NSString).expandingTildeInPath }

    /// The "Save to" dropdown rows: the two presets, the by-type rule, any folder
    /// the user picked through the panel, then a separated "Choose folder…".
    private var saveOptions: [Dropdown<String>.Item] {
        var options: [Dropdown<String>.Item] = [
            .option(downloadsPath, "~/Downloads"),
            .option(moviesPath, "~/Movies"),
            .option(SaveOption.automatic, "Automatic (by type)"),
        ]
        if let customFolder, customFolder != downloadsPath, customFolder != moviesPath {
            options.append(.option(customFolder, (customFolder as NSString).abbreviatingWithTildeInPath))
        }
        options.append(.separator)
        options.append(.option(SaveOption.choose, "Choose folder…"))
        return options
    }

    /// The "Then send to" rows: stay local, plus every server whose identity is already pinned.
    private var serverOptions: [Dropdown<String>.Item] {
        [.option(ServerOption.none, "Keep it on this Mac")]
            + vm.destinationServers.map { .option($0.id.uuidString, $0.label) }
    }

    private var selectedServer: SFTPConnection? {
        vm.destinationServers.first { $0.id.uuidString == remoteSelection }
    }

    private var remoteFolderError: String? {
        selectedServer == nil ? nil : vm.destinationFolderError(remoteDirectory)
    }

    /// The destination to attach, or nil when the download is staying local.
    private var resolvedRemoteDestination: RemoteDestination? {
        guard let selectedServer, remoteFolderError == nil else { return nil }
        return vm.makeDestination(for: selectedServer,
                                  directory: remoteDirectory,
                                  removeLocalAfterUpload: remoteRemoveLocal)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch phase {
            case .input:        inputContent
            case .resolving:    resolvingContent
            case .confirm(let preview): confirmContent(preview)
            }
        }
        .frame(width: 560)
        .onAppear(perform: autoPasteFromClipboard)
        // Closing the sheet must stop any in-flight yt-dlp work, or the subprocess
        // keeps running headless after the user has walked away.
        .onDisappear {
            resolveTask?.cancel()
            subtitleTask?.cancel()
        }
    }

    // MARK: Header

    private var header: some View {
        SheetHeader(systemImage: phase == .input ? "link" : "checklist",
                    title: phase == .input ? "Add download" : "Review & start")
    }

    // MARK: Step 1 — input

    private var inputContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                dropZone

                VStack(alignment: .leading, spacing: 6) {
                    Text("URL, magnet, or .m3u8 stream")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                        .onChange(of: text) { _, _ in inputError = nil }
                    if let inputError {
                        Label(inputError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.orange)
                    } else {
                        Text("Paste several lines to add them all at once (batch). Patterns expand too: file[01-20].zip or file.{iso,sig}. A single link is previewed before it starts.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { continueTapped() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
    }

    // MARK: Step 1.5 — resolving spinner

    private var resolvingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Fetching details…")
                .font(.system(size: 13, weight: .medium))
            Text("Reading the file name and size. Magnet links ask peers for the file list, which can take a few seconds.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Cancel") {
                    resolveTask?.cancel()
                    phase = .input
                }
                // Don't wait for the preview: queue it now and let the details
                // resolve while it downloads (a single metadata pass, not two).
                Button("Continue anyway") { continueWithoutPreview() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            Text("Continue anyway adds it straight to the queue — the name and size fill in as it starts.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    /// Skip the metadata wait: cancel the in-flight resolve and queue the source
    /// immediately, so it resolves once — during the download — instead of twice.
    private func continueWithoutPreview() {
        resolveTask?.cancel()
        if let line = firstParseableLine() {
            vm.add(rawLines: line, saveDirectory: resolvedSaveDirectory, priority: priority)
        }
        dismiss()
    }

    // MARK: Step 2 — confirm

    private func confirmContent(_ preview: DownloadPreview) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                metadataSummary(preview)

                if let duplicate = vm.existingDuplicate(of: preview.source) {
                    Label("Already in your list (\(duplicate.status.displayName.lowercased())) — starting it again won’t add a second copy.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !preview.files.isEmpty {
                    fileList(preview.files, selectable: preview.kind == .torrent)
                }

                if let note = preview.note {
                    Label(note, systemImage: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Save to").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Dropdown(selection: $saveSelection, items: saveOptions) { newValue in
                            handleSaveSelection(newValue)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Dropdown(selection: $priority, items: [
                            .option(.high, "High"),
                            .option(.normal, "Normal"),
                            .option(.low, "Low"),
                        ], width: 120)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Dropdown(selection: $startSelection, items: startOptions, width: 150)
                    }
                }

                serverDestinationSection(preview)
                if preview.kind != .torrent {
                    checksumField
                }
                if preview.kind == .http {
                    mirrorsField
                }
                if preview.kind == .http, YtDlpResolver.isAvailable {
                    ytDlpRow(preview)
                }
            }
            .padding(20)

            Divider()
            HStack {
                Button("Back") { deselectedFileIDs = []; phase = .input }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start download") { start(preview) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(remoteFolderError != nil)
            }
            .padding(14)
        }
    }

    /// Name + kind badge + size header for the confirm screen.
    private func metadataSummary(_ preview: DownloadPreview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preview.kind.symbolName)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.suggestedName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    kindBadge(preview.kind)
                    Text(sizeText(preview))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if !preview.files.isEmpty {
                        Text("· \(preview.files.count) file\(preview.files.count == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    /// Scrollable list of the files inside a torrent. When `selectable`, each
    /// file gets a tick so the user can choose what to download before it starts;
    /// unticked files are recorded in `deselectedFileIDs` and skipped on add.
    private func fileList(_ files: [TransferFile], selectable: Bool) -> some View {
        let selectedCount = files.count - files.filter { deselectedFileIDs.contains($0.id) }.count
        let selectedBytes = files.filter { !deselectedFileIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.length }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if selectable {
                    Text("\(selectedCount) of \(files.count) · \(selectedBytes.byteString)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        let wanted = !deselectedFileIDs.contains(file.id)
                        HStack(spacing: 8) {
                            if selectable {
                                Button {
                                    if wanted { deselectedFileIDs.insert(file.id) }
                                    else { deselectedFileIDs.remove(file.id) }
                                } label: {
                                    Image(systemName: wanted ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(wanted ? Theme.accent : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            Text((file.path as NSString).lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundStyle(wanted ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(file.length.byteString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        if file.id != files.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(files.count) * 28 + 4, 170))
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
    }

    // MARK: Shared subviews

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isDropTargeted ? Theme.accent : .secondary)
            (Text("Drag a URL or ") + Text(".torrent").bold() + Text(" file here"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.hairline,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        .animation(.easeInOut(duration: 0.08), value: isDropTargeted)
    }

    /// Optional forwarding to a saved server. The download still lands locally first — this only says where it goes afterwards.
    ///
    /// Hidden for torrents: a torrent's payload may turn out to be a folder of files, which the transfer cannot send, and that is not known until the metadata resolves. A finished single-file torrent can still be sent from its context menu.
    @ViewBuilder
    private func serverDestinationSection(_ preview: DownloadPreview) -> some View {
        if vm.isSendToServerEnabled, preview.kind != .torrent, !vm.destinationServers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Then send to (optional)")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Dropdown(selection: $remoteSelection, items: serverOptions) { newValue in
                    remoteDirectory = vm.destinationServers
                        .first { $0.id.uuidString == newValue }?.resolvedUploadPath ?? "."
                }
                .frame(maxWidth: .infinity)
                if selectedServer != nil {
                    TextField("Folder on the server", text: $remoteDirectory)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    if let remoteFolderError {
                        Text(remoteFolderError).font(.system(size: 11)).foregroundStyle(Theme.red)
                    }
                    Toggle("Remove the local copy once it lands", isOn: $remoteRemoveLocal)
                        .font(.system(size: 12))
                    Text("It downloads here first, then transfers. Nothing local is deleted until the server confirms the full size.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var checksumField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checksum (optional)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("MD5, SHA-1, or SHA-256 hex", text: $checksumText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
            if !checksumText.trimmingCharacters(in: .whitespaces).isEmpty {
                if let parsed = Checksum.parse(checksumText) {
                    Label("\(parsed.algorithm.displayName) — verified after the download finishes",
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.green)
                } else {
                    Label("Not a valid MD5 / SHA-1 / SHA-256 hex digest",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
    }

    /// Offered only when the user has yt-dlp installed: swap a video-site page
    /// URL for the direct media stream it plays.
    private func ytDlpRow(_ preview: DownloadPreview) -> some View {
        HStack(spacing: 8) {
            if isResolvingMedia {
                ProgressView().controlSize(.small)
                Text("Asking yt-dlp…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Resolve Media with yt-dlp") { resolveWithYtDlp(preview) }
                Text("For video-site pages: download the stream, not the page.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func resolveWithYtDlp(_ preview: DownloadPreview) {
        guard case .url(let pageURL) = preview.source else { return }
        isResolvingMedia = true
        resolveTask = Task { @MainActor in
            defer { isResolvingMedia = false }
            if let resolved = await YtDlpResolver.resolve(pageURL),
               let mediaPreview = YtDlpResolver.preview(for: resolved) {
                phase = .confirm(mediaPreview)
                // Optionally fetch subtitles for the original page into the same
                // folder, named to sit beside the video. Fire-and-forget.
                if vm.settings.subtitleDownloadEnabled {
                    let dir = resolvedSaveDirectory ?? vm.settings.defaultSaveDirectory
                    let base = (mediaPreview.suggestedName as NSString).deletingPathExtension
                    let langs = vm.settings.subtitleLanguages
                    let auto = vm.settings.subtitleIncludeAutoGenerated
                    subtitleTask = Task {
                        let outcome = await YtDlpResolver.downloadSubtitles(
                            pageURL: pageURL, into: dir, baseName: base,
                            languages: langs, includeAuto: auto)
                        await MainActor.run {
                            switch outcome {
                            case .downloaded(let n):
                                vm.toastNow("Downloaded \(n) subtitle file\(n == 1 ? "" : "s")")
                            case .none:
                                break   // no subtitles for this video — expected, stay quiet
                            case .failed(let msg):
                                vm.toastNow("Subtitles: \(msg)")
                            }
                        }
                    }
                }
            } else {
                inputError = nil
                vm.toast = "yt-dlp couldn’t resolve that page"
            }
        }
    }

    private var mirrorsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mirrors (optional, one per line)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $mirrorsText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 44)
                .padding(4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            Text("Alternative URLs for the same file — segments spread across them and fail over automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Actions

    /// Pre-fill the field from the clipboard when it holds a downloadable link and
    /// the field is still empty.
    private func autoPasteFromClipboard() {
        guard text.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty,
              AppViewModel.parseSource(clip) != nil
        else { return }
        text = clip
    }

    /// Continue from the input step: one link → resolve + preview; many → batch add.
    private func continueTapped() {
        let sources = vm.parsedSources(in: text)
        guard !sources.isEmpty else {
            inputError = "Enter a valid URL, magnet, or .m3u8 link."
            return
        }
        if sources.count > 1 {
            vm.add(rawLines: text, saveDirectory: resolvedSaveDirectory, priority: priority)
            dismiss()
            return
        }
        guard let line = firstParseableLine() else {
            inputError = "Enter a valid URL, magnet, or .m3u8 link."
            return
        }
        // A fresh resolution gets a clean slate: a checksum or mirror list
        // entered for a previous link (then Back, then a different link) must
        // never silently apply to this one.
        checksumText = ""
        mirrorsText = ""
        phase = .resolving
        resolveTask = Task { @MainActor in
            let preview = await vm.resolveMetadata(for: line, saveDirectory: nil)
            if Task.isCancelled { return }
            if let preview {
                // Pre-fill a checksum the server itself published (Digest /
                // Content-MD5 header or a .sha256 sidecar) — visible and
                // editable, never silently applied.
                if let suggested = preview.suggestedChecksum,
                   checksumText.trimmingCharacters(in: .whitespaces).isEmpty {
                    checksumText = suggested.value
                }
                phase = .confirm(preview)
            } else {
                phase = .input
                inputError = "That link isn’t valid."
            }
        }
    }

    /// The "Start" dropdown rows: now, plus the scheduled presets.
    private var startOptions: [Dropdown<String>.Item] {
        [.option("now", "Now")]
            + ScheduledStartOption.presets.map { .option($0.id, $0.label) }
    }

    /// Commit the previewed download with the chosen destination/priority/checksum.
    private func start(_ preview: DownloadPreview) {
        let startAt = ScheduledStartOption.presets
            .first { $0.id == startSelection }?
            .date()
        let mirrors = mirrorsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Only forward deselections that map to a file in this preview (guards
        // against stale indices from a previously previewed torrent).
        let validIDs = Set(preview.files.map(\.id))
        let skip = deselectedFileIDs.filter(validIDs.contains).sorted()
        vm.confirm(preview, saveDirectory: resolvedSaveDirectory, priority: priority,
                   checksum: Checksum.parse(checksumText), startAt: startAt,
                   mirrors: mirrors.isEmpty ? nil : mirrors,
                   deselectedFileIDs: skip.isEmpty ? nil : skip,
                   remoteDestination: resolvedRemoteDestination)
        dismiss()
    }

    private func firstParseableLine() -> String? {
        // Expand batch patterns first (via the same path parsedSources uses), so a
        // single-line range that collapses to one URL resolves/queues the expanded
        // target — not the raw, literal-bracket string.
        AppViewModel.expandedLines(text)
            .first { AppViewModel.parseSource($0) != nil }
    }

    /// The directory to hand the manager. `automatic` (and the unreachable
    /// `choose` sentinel) map to `nil` so the configured default-folder rule wins.
    private var resolvedSaveDirectory: String? {
        switch saveSelection {
        case SaveOption.automatic, SaveOption.choose: return nil
        default: return saveSelection
        }
    }

    private func handleSaveSelection(_ newValue: String) {
        guard newValue == SaveOption.choose else {
            previousSaveSelection = newValue
            return
        }
        if let url = FilePicker.chooseDirectory() {
            customFolder = url.path
            saveSelection = url.path
            previousSaveSelection = url.path
        } else {
            saveSelection = previousSaveSelection
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedURLs(providers) { urls in
            guard !urls.isEmpty else { return }
            // Local .torrent files can't go through the text field: DownloadSource.parse
            // rejects the file: scheme. Route them the way an explicit file-open does —
            // via ExternalAdd, which special-cases .torrent files — and append only the
            // remaining remote/magnet URLs as parseable lines.
            let isTorrentFile: (URL) -> Bool = { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" }
            let torrentFiles = urls.filter(isTorrentFile)
            let others = urls.filter { !isTorrentFile($0) }
            if !others.isEmpty {
                appendLines(others.map(\.absoluteString))
            }
            guard !torrentFiles.isEmpty else { return }
            Task { @MainActor in
                for url in torrentFiles {
                    if var payload = ExternalAdd.payload(from: url) {
                        payload.needsConfirmation = false
                        ExternalAdd.post(payload)
                    }
                }
                // The torrent(s) are queued directly, as torrent files are everywhere
                // else. Close the sheet when the drop carried nothing else to preview.
                if others.isEmpty { dismiss() }
            }
        }
    }

    private func appendLines(_ lines: [String]) {
        let joined = lines.joined(separator: "\n")
        if text.isEmpty {
            text = joined
        } else if text.hasSuffix("\n") {
            text += joined
        } else {
            text += "\n" + joined
        }
    }

    // MARK: Formatting helpers

    private func sizeText(_ preview: DownloadPreview) -> String {
        guard let bytes = preview.totalBytes else {
            return preview.isEstimatedSize ? "Size resolved while downloading" : "Unknown size"
        }
        return (preview.isEstimatedSize ? "~" : "") + bytes.byteString
    }

    private func kindBadge(_ kind: DownloadKind) -> some View {
        let label: String
        let color: Color
        switch kind {
        case .http: label = "HTTP"; color = Theme.accent
        case .torrent: label = "BT"; color = Theme.green
        case .hls: label = "HLS"; color = Theme.orange
        case .ftp: label = "FTP"; color = Theme.teal
        case .sftp: label = "SFTP"; color = Theme.indigo
        }
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
