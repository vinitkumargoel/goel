import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case input
        case resolving
        case confirm(DownloadPreview)
        case playlist(URL)
    }
    @State private var phase: Phase = .input
    @State private var deselectedFileIDs: Set<Int> = []

    @State private var text: String = ""
    @State private var priority: FilePriority = .normal
    @State private var isDropTargeted = false
    @State private var checksumText: String = ""
    @State private var mirrorsText: String = ""
    @State private var isResolvingMedia = false
    @State private var inputError: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolvedPageURL: URL?

    @State private var cookieSource: CookieSource = .none

    /// A live bearer credential: plain `@State` on purpose, never `@AppStorage` or any other store.
    @State private var pastedCookies: String = ""

    var capturedCookies: String? = nil

    @State private var chosenFormat: MediaFormat?

    @State private var startSelection: String = "now"

    @State private var saveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    @State private var previousSaveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    @State private var customFolder: String?

    private enum SaveOption {
        static let automatic = "automatic"
        static let choose = "__choose__"
    }

    private var downloadsPath: String { ("~/Downloads" as NSString).expandingTildeInPath }
    private var moviesPath: String { ("~/Movies" as NSString).expandingTildeInPath }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch phase {
            case .input:        inputContent
            case .resolving:    resolvingContent
            case .confirm(let preview): confirmContent(preview)
            case .playlist(let url):
                PlaylistChecklistView(playlistURL: url) { items in
                    vm.add(rawLines: items.map(\.url).joined(separator: "\n"),
                           saveDirectory: resolvedSaveDirectory, priority: priority)
                    dismiss()
                }
            }
        }
        .frame(width: 560)
        .onAppear(perform: autoPasteFromClipboard)
        // Without this cancel the yt-dlp subprocess keeps running headless after the sheet closes.
        .onDisappear { resolveTask?.cancel() }
    }

    private var header: some View {
        SheetHeader(systemImage: phase == .input ? "link" : "checklist",
                    title: phase == .input ? "Add download" : "Review & start")
    }

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
                        .accessibilityLabel("URL, magnet, or m3u8 stream")
                        .accessibilityHint("Paste one link per line to add several at once.")
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                        .onChange(of: text) { _, _ in inputError = nil }
                    if let inputError {
                        Label(inputError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.orange)
                            .accessibilityLabel("Error. \(inputError)")
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

    private var resolvingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Fetching details")
            Text("Fetching details…")
                .font(.system(size: 13, weight: .medium))
                .accessibilityAddTraits(.isHeader)
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

    private func continueWithoutPreview() {
        resolveTask?.cancel()
        if let line = firstParseableLine() {
            vm.add(rawLines: line, saveDirectory: resolvedSaveDirectory, priority: priority)
        }
        dismiss()
    }

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

                if allFilesDeselected(preview) {
                    Label("Pick at least one file to download.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
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

                if preview.kind != .torrent {
                    checksumField
                }
                if preview.kind == .http {
                    mirrorsField
                }
                CookieSourcePicker(host: previewHost(preview),
                                   source: $cookieSource,
                                   pastedCookies: $pastedCookies,
                                   capturedCookies: capturedCookies)
                if preview.kind == .http, YtDlpResolver.isAvailable {
                    ytDlpRow(preview)
                    // This list spawns `yt-dlp -F` just by appearing, so mount it only for a video *page*.
                    if case .url(let pageURL) = preview.source,
                       !preview.source.looksLikeDownloadableFile,
                       resolvedPageURL == nil {
                        MediaFormatPicker(pageURL: pageURL) { chosenFormat = $0 }
                    }
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
                    // A second press during a resolve queues a second copy; an all-unticked torrent fetches nothing.
                    .disabled(isResolvingMedia || allFilesDeselected(preview))
            }
            .padding(14)
        }
    }

    private func allFilesDeselected(_ preview: DownloadPreview) -> Bool {
        preview.kind == .torrent
            && !preview.files.isEmpty
            && deselectedFileIDs.isSuperset(of: Set(preview.files.map(\.id)))
    }

    private func metadataSummary(_ preview: DownloadPreview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preview.kind.symbolName)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.suggestedName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
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
                                .a11yButton(wanted
                                    ? "Skip \((file.path as NSString).lastPathComponent)"
                                    : "Download \((file.path as NSString).lastPathComponent)")
                                .accessibilityValue(wanted ? "Included" : "Skipped")
                            } else {
                                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .a11yDecorative()
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
                                .accessibilityLabel(A11y.bytes(file.length))
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

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isDropTargeted ? Theme.accent : .secondary)
                .a11yDecorative()
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

    private var checksumField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checksum (optional)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("MD5, SHA-1, or SHA-256 hex", text: $checksumText)
                .accessibilityLabel("Expected checksum")
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

    private func ytDlpRow(_ preview: DownloadPreview) -> some View {
        HStack(spacing: 8) {
            if isResolvingMedia {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Resolving media formats")
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
            switch await YtDlpResolver.resolveMedia(pageURL, formatSelector: chosenFormat?.id) {
            case .resolved(let resolved):
                guard let mediaPreview = YtDlpResolver.preview(for: resolved) else {
                    inputError = nil
                    vm.toast = "yt-dlp couldn’t resolve that page"
                    return
                }
                // Don't fetch subtitles here: "Save to" is still editable, so sidecars would be orphaned.
                resolvedPageURL = pageURL
                phase = .confirm(mediaPreview)
            case .cancelled:
                break
            case .failed(let reason):
                inputError = nil
                vm.toast = reason
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

    private func autoPasteFromClipboard() {
        guard text.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty,
              AppViewModel.parseSource(clip) != nil
        else { return }
        text = clip
    }

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
        // Reset every per-link field: state left from the previous link would silently apply to this one.
        checksumText = ""
        mirrorsText = ""
        chosenFormat = nil
        resolvedPageURL = nil
        // Without the checklist a playlist link resolves to one video and silently drops the rest.
        if YtDlpResolver.isAvailable,
           PlaylistExpander.looksLikePlaylist(line),
           let url = URL(string: line) {
            phase = .playlist(url)
            return
        }
        phase = .resolving
        resolveTask = Task { @MainActor in
            let preview = await vm.resolveMetadata(for: line, saveDirectory: nil)
            if Task.isCancelled { return }
            if let preview {
                // A server-published checksum is only ever pre-filled: visible and editable, never auto-applied.
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

    private var startOptions: [Dropdown<String>.Item] {
        [.option("now", "Now")]
            + ScheduledStartOption.presets.map { .option($0.id, $0.label) }
    }

    /// A picked-but-unresolved page must be resolved with that format id first, or the HTML gets queued.
    private func start(_ preview: DownloadPreview) {
        if let chosenFormat, resolvedPageURL == nil, case .url = preview.source {
            resolveThenCommit(preview, formatSelector: chosenFormat.id)
        } else {
            commit(preview)
        }
    }

    private func resolveThenCommit(_ preview: DownloadPreview, formatSelector: String) {
        guard case .url(let pageURL) = preview.source else { return commit(preview) }
        isResolvingMedia = true
        resolveTask = Task { @MainActor in
            defer { isResolvingMedia = false }
            guard let resolved = await YtDlpResolver.resolve(pageURL, formatSelector: formatSelector),
                  let mediaPreview = YtDlpResolver.preview(for: resolved) else {
                if Task.isCancelled { return }
                vm.toast = "yt-dlp couldn’t resolve that page"
                return
            }
            resolvedPageURL = pageURL
            commit(mediaPreview)
        }
    }

    private func commit(_ preview: DownloadPreview) {
        let startAt = ScheduledStartOption.presets
            .first { $0.id == startSelection }?
            .date()
        let mirrors = mirrorsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Filter to this preview's ids: stale indices from a previously previewed torrent skip wrong files.
        let validIDs = Set(preview.files.map(\.id))
        let skip = deselectedFileIDs.filter(validIDs.contains).sorted()
        vm.confirm(preview, saveDirectory: resolvedSaveDirectory, priority: priority,
                   checksum: Checksum.parse(checksumText), startAt: startAt,
                   mirrors: mirrors.isEmpty ? nil : mirrors,
                   deselectedFileIDs: skip.isEmpty ? nil : skip,
                   cookieHeader: cookieHeaderToAttach,
                   cookieSource: cookieSource,
                   cookieHost: previewHost(preview))
        fetchSubtitlesIfWanted(for: preview)
        dismiss()
    }

    /// The inner Task is untracked on purpose: the sheet closes next line, yt-dlp's watchdog bounds it.
    private func fetchSubtitlesIfWanted(for preview: DownloadPreview) {
        guard vm.settings.subtitleDownloadEnabled, let pageURL = resolvedPageURL else { return }
        guard let directory = subtitleDestination else {
            vm.toastNow("Subtitles skipped — pick a folder under “Save to” so they land beside the video")
            return
        }
        let base = (preview.suggestedName as NSString).deletingPathExtension
        let langs = vm.settings.subtitleLanguages
        let auto = vm.settings.subtitleIncludeAutoGenerated
        Task { @MainActor in
            let outcome = await YtDlpResolver.downloadSubtitles(
                pageURL: pageURL, into: directory, baseName: base,
                languages: langs, includeAuto: auto)
            switch outcome {
            case .downloaded(let n):
                vm.toastNow("Downloaded \(n) subtitle file\(n == 1 ? "" : "s")")
            case .none:
                break
            case .failed(let msg):
                vm.toastNow("Subtitles: \(msg)")
            }
        }
    }

    private var subtitleDestination: String? {
        if let resolvedSaveDirectory { return resolvedSaveDirectory }
        switch vm.settings.defaultFolderRule {
        case "byType", "automatic", "bySource": return nil
        default: return vm.settings.defaultSaveDirectory
        }
    }

    /// Callers must never read ``pastedCookies`` directly — only this sanitised value leaves the sheet.
    private var cookieHeaderToAttach: String? {
        switch cookieSource {
        case .none:    return nil
        case .browser: return capturedCookies.flatMap(CookieHeader.sanitized)
        case .manual:  return CookieHeader.sanitized(pastedCookies)
        }
    }

    private func previewHost(_ preview: DownloadPreview) -> String? {
        switch preview.source {
        case .url(let url), .hlsStream(let url): return url.host
        case .magnet, .torrentFile: return nil
        }
    }

    private func firstParseableLine() -> String? {
        // Expand patterns first, or a one-line range resolves the literal `file[01-20].zip` string.
        AppViewModel.expandedLines(text)
            .first { AppViewModel.parseSource($0) != nil }
    }

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
            // `DownloadSource.parse` rejects `file:`, so local .torrent drops must go via ExternalAdd.
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
