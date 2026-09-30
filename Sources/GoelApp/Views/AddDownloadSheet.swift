import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Shown under the yt-dlp row: a toast would draw in the main window, behind this sheet.
    @State private var ytDlpError: String?
    /// The text the clipboard put in the box; the "Pasted from clipboard" note shows while it's unchanged.
    @State private var pastedText: String?
    @State private var showAdvanced = false

    @State private var cookieSource: CookieSource = .none

    /// A live bearer credential: plain `@State` on purpose, never `@AppStorage` or any other store.
    @State private var pastedCookies: String = ""

    var capturedCookies: String? = nil

    @State private var chosenFormat: MediaFormat?

    @State private var startSelection: String = "now"

    @State private var saveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    @State private var previousSaveSelection: String = ("~/Downloads" as NSString).expandingTildeInPath
    @State private var customFolder: String?

    /// Free space on the chosen folder's volume; refreshed when the folder changes, not per frame.
    @State private var freeBytes: Int64?

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
            .option(SaveOption.automatic, L10n.t("Automatic (by type)")),
        ]
        if let customFolder, customFolder != downloadsPath, customFolder != moviesPath {
            options.append(.option(customFolder, (customFolder as NSString).abbreviatingWithTildeInPath))
        }
        options.append(.separator)
        options.append(.option(SaveOption.choose, L10n.t("Choose folder…")))
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
                PlaylistChecklistView(
                    playlistURL: url,
                    sheetActions: .init(
                        back: { phase = .input },
                        singleVideo: {
                            if let line = firstParseableLine() { resolveSingle(line) }
                        },
                        cancel: { dismiss() })
                ) { items in
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
                    title: phase == .input ? L10n.t("Add download") : L10n.t("Review & start"))
    }

    private var inputContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                dropZone

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("URL, magnet, or .m3u8 stream"))
                            .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let pastedText, pastedText == text {
                            PastedFromClipboardNote {
                                text = ""
                                self.pastedText = nil
                            }
                        }
                    }
                    TextEditor(text: $text)
                        .scaledFont(size: Theme.TextSize.body, design: .monospaced)
                        .accessibilityLabel(L10n.t("URL, magnet, or m3u8 stream"))
                        .accessibilityHint(L10n.t("Paste one link per line to add several at once."))
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.hairline))
                        .onChange(of: text) { _, _ in inputError = nil }
                    if let inputError {
                        Label(inputError, systemImage: "exclamationmark.triangle.fill")
                            .scaledFont(size: Theme.TextSize.meta)
                            .foregroundStyle(Theme.orange)
                            .accessibilityLabel(L10n.t("Error. %@", inputError))
                    } else {
                        Text(L10n.t("Paste several lines to add them all at once (batch). Patterns expand too: file[01-20].zip or file.{iso,sig}. A single link is previewed before it starts.")
                             + " " + L10n.t("Press ⌘↩ to continue."))
                            .scaledFont(size: Theme.TextSize.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩, not ↩: the focused editor takes a plain Return as a new line.
                Button(L10n.t("Continue")) { continueTapped() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(L10n.t("Continue (⌘↩)"))
            }
            .padding(14)
        }
    }

    private var resolvingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(L10n.t("Fetching details"))
            Text(L10n.t("Fetching details…"))
                .scaledFont(size: Theme.TextSize.title, weight: .medium)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("Reading the file name and size. Magnet links ask peers for the file list, which can take a few seconds."))
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button(L10n.t("Cancel")) {
                    resolveTask?.cancel()
                    phase = .input
                }
                Button(L10n.t("Continue anyway")) { continueWithoutPreview() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            Text(L10n.t("Continue anyway adds it straight to the queue — the name and size fill in as it starts."))
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
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

    /// Back from the confirm step: a yt-dlp resolve still running would otherwise flip the phase
    /// or commit the download after the user left.
    private func goBack() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolvingMedia = false
        deselectedFileIDs = []
        ytDlpError = nil
        phase = .input
    }

    /// Leaves room for the sheet's header and footer, the window title and the menu bar.
    private var confirmBodyMaxHeight: CGFloat {
        CappedScrollView<EmptyView>.screenCap(reserving: 220, upTo: 560)
    }

    private func confirmContent(_ preview: DownloadPreview) -> some View {
        VStack(spacing: 0) {
            CappedScrollView(maxHeight: confirmBodyMaxHeight) {
                confirmBody(preview)
            }
            .task(id: diskSpaceFolder(for: preview)) { await refreshFreeSpace(in: diskSpaceFolder(for: preview)) }
            .onAppear {
                showAdvanced = AddSheetInput.advancedHasContent(
                    checksum: checksumText, mirrors: mirrorsText, cookieSource: cookieSource,
                    hasCapturedCookies: capturedCookies != nil)
            }

            Divider()
            HStack {
                Button(L10n.t("Back")) { goBack() }
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(unreachableMessage(preview) == nil ? L10n.t("Start download") : L10n.t("Continue anyway")) {
                    start(preview)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // A second press during a resolve queues a second copy; an all-unticked torrent fetches nothing.
                .disabled(isResolvingMedia || allFilesDeselected(preview))
            }
            .padding(14)
        }
    }

    /// The reason the preview came back empty, for links whose server answered badly or not at all.
    /// A torrent without peers yet and a yt-dlp stream keep their plain informational note.
    private func unreachableMessage(_ preview: DownloadPreview) -> String? {
        guard resolvedPageURL == nil, let note = preview.note else { return nil }
        switch preview.kind {
        case .http, .ftp, .sftp:
            return AddSheetInput.resolveFailureMessage(host: previewHost(preview), reason: note,
                                                       isGenericUnreachable: preview.noteIsGenericUnreachable)
        case .torrent, .hls:
            return nil
        }
    }

    private func resolveFailureBlock(_ message: String, preview: DownloadPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(Theme.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.t("Error. %@", message))
            HStack(spacing: 8) {
                Button(L10n.t("Try again")) {
                    if let line = firstParseableLine() { resolveSingle(line, keepFields: true) }
                }
                .controlSize(.small)
                Button(L10n.t("Continue anyway")) { start(preview) }
                    .controlSize(.small)
                    .disabled(isResolvingMedia || allFilesDeselected(preview))
                    .help(L10n.t("Continue anyway adds it straight to the queue — the name and size fill in as it starts."))
            }
        }
    }

    private func confirmBody(_ preview: DownloadPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AddSheetMetadataSummary(preview: preview, sizeText: sizeText(preview))

            if let duplicate = vm.existingDuplicate(of: preview.source) {
                Label(L10n.t("Already in your list (%@) — starting it again won’t add a second copy.",
                           L10n.midSentence(L10n.t(duplicate.status.displayName))),
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !preview.files.isEmpty {
                AddSheetFileList(files: preview.files, selectable: preview.kind == .torrent,
                                 deselectedFileIDs: $deselectedFileIDs)
            }

            if allFilesDeselected(preview) {
                Label(L10n.t("Pick at least one file to download."),
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = unreachableMessage(preview) {
                resolveFailureBlock(failure, preview: preview)
            } else if let note = preview.note {
                Label(note, systemImage: "info.circle.fill")
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("Save to")).scaledFont(size: Theme.TextSize.body, weight: .semibold).foregroundStyle(.secondary)
                    Dropdown(selection: $saveSelection, items: saveOptions) { newValue in
                        handleSaveSelection(newValue)
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("Priority")).scaledFont(size: Theme.TextSize.body, weight: .semibold).foregroundStyle(.secondary)
                    Dropdown(selection: $priority, items: [
                        .option(.high, L10n.t("High")),
                        .option(.normal, L10n.t("Normal")),
                        .option(.low, L10n.t("Low")),
                    ], width: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("Start")).scaledFont(size: Theme.TextSize.body, weight: .semibold).foregroundStyle(.secondary)
                    Dropdown(selection: $startSelection, items: startOptions, width: 150)
                }
            }

            diskSpaceRow(preview)

            // A torrent has no checksum, mirror or per-host cookie to offer.
            if preview.kind != .torrent || previewHost(preview) != nil {
                advancedOptions(preview)
            }

            if preview.kind == .http, YtDlpResolver.isAvailable {
                AddSheetYtDlpRow(isResolving: isResolvingMedia) { resolveWithYtDlp(preview) }
                if let ytDlpError {
                    Label(ytDlpError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: Theme.TextSize.meta)
                        .foregroundStyle(Theme.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.t("Error. %@", ytDlpError))
                }
                // This list spawns `yt-dlp -F` just by appearing, so mount it only for a video *page*.
                if case .url(let pageURL) = preview.source,
                   !preview.source.looksLikeDownloadableFile,
                   resolvedPageURL == nil {
                    MediaFormatPicker(pageURL: pageURL) { chosenFormat = $0 }
                }
            }
        }
        .padding(20)
    }

    private func advancedOptions(_ preview: DownloadPreview) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 16) {
                if preview.kind != .torrent {
                    AddSheetChecksumField(text: $checksumText)
                }
                if preview.kind == .http {
                    AddSheetMirrorsField(text: $mirrorsText)
                }
                CookieSourcePicker(host: previewHost(preview),
                                   source: $cookieSource,
                                   pastedCookies: $pastedCookies,
                                   capturedCookies: capturedCookies)
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Text(L10n.t("Advanced options"))
                    .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(advancedSummary(preview))
                    .scaledFont(size: Theme.TextSize.meta)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            // macOS's DisclosureGroup toggles only from its chevron; this makes the label a target too.
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { showAdvanced.toggle() }
            }
        }
    }

    private func advancedSummary(_ preview: DownloadPreview) -> String {
        // Only what ``advancedOptions(_:)`` shows: mirrors for HTTP alone, no checksum for a torrent.
        switch preview.kind {
        case .http: return L10n.t("checksum, mirrors, cookies")
        case .torrent: return L10n.t("cookies")
        case .hls, .ftp, .sftp: return L10n.t("checksum, cookies")
        }
    }

    /// The folder whose volume the space check asks about: the one "Automatic" really resolves
    /// to for this download (a `Video` subfolder may be a link onto another disk).
    private func diskSpaceFolder(for preview: DownloadPreview) -> String {
        resolvedSaveDirectory ?? DiskSpaceCheck.automaticFolder(for: preview.source,
                                                                suggestedName: preview.suggestedName,
                                                                settings: vm.settings)
    }

    private func refreshFreeSpace(in folder: String) async {

        let free = await Task.detached(priority: .userInitiated) {
            DiskSpaceCheck.availableCapacity(forFolder: folder)
        }.value
        if !Task.isCancelled { freeBytes = free }
    }

    /// Bytes this preview will write: for a torrent, only the files still ticked.
    private func neededBytes(_ preview: DownloadPreview) -> Int64? {
        if preview.kind == .torrent, !preview.files.isEmpty {
            let wanted = preview.files.filter { !deselectedFileIDs.contains($0.id) }
            return wanted.reduce(Int64(0)) { $0 + $1.length }
        }
        return preview.totalBytes
    }

    @ViewBuilder
    private func diskSpaceRow(_ preview: DownloadPreview) -> some View {
        if let verdict = DiskSpaceCheck.verdict(needed: neededBytes(preview), available: freeBytes) {
            VStack(alignment: .leading, spacing: 4) {
                Label(DiskSpaceCheck.message(for: verdict),
                      systemImage: verdict.isSufficient ? "internaldrive" : "exclamationmark.triangle.fill")
                    .scaledFont(size: Theme.TextSize.meta, weight: verdict.isSufficient ? .regular : .semibold)
                    .foregroundStyle(verdict.isSufficient ? Color.secondary : Theme.red)
                    .accessibilityLabel(DiskSpaceCheck.spokenMessage(for: verdict))
                if !verdict.isSufficient {
                    HStack(spacing: 8) {
                        Text(L10n.t("There isn’t enough free space on this disk. The download would stop partway."))
                            .scaledFont(size: Theme.TextSize.meta)
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.t("Choose another folder…")) {
                            saveSelection = SaveOption.choose
                            handleSaveSelection(SaveOption.choose)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func allFilesDeselected(_ preview: DownloadPreview) -> Bool {
        preview.kind == .torrent
            && !preview.files.isEmpty
            && deselectedFileIDs.isSuperset(of: Set(preview.files.map(\.id)))
    }

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .scaledFont(size: 22, weight: .regular)
                .foregroundStyle(isDropTargeted ? Theme.accent : .secondary)
                .a11yDecorative()
            Text(MarkdownText.attributed(L10n.t("Drag a URL or **.torrent** file here")))
                .scaledFont(size: Theme.TextSize.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(isDropTargeted ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.hairline,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        .animation(.easeInOut(duration: 0.08), value: isDropTargeted)
    }

    private func resolveWithYtDlp(_ preview: DownloadPreview) {
        guard case .url(let pageURL) = preview.source else { return }
        ytDlpError = nil
        resolveTask?.cancel()
        isResolvingMedia = true
        resolveTask = Task { @MainActor in
            // A cancelled resolve leaves the flag to whoever cancelled it (Back, or a newer resolve).
            defer { if !Task.isCancelled { isResolvingMedia = false } }
            let outcome = await YtDlpResolver.resolveMedia(pageURL, formatSelector: chosenFormat?.id)
            if Task.isCancelled { return }
            switch outcome {
            case .resolved(let resolved):
                guard let mediaPreview = YtDlpResolver.preview(for: resolved) else {
                    inputError = nil
                    ytDlpError = L10n.t("yt-dlp couldn’t resolve that page")
                    return
                }
                // Don't fetch subtitles here: "Save to" is still editable, so sidecars would be orphaned.
                resolvedPageURL = pageURL
                phase = .confirm(mediaPreview)
            case .cancelled:
                break
            case .failed(let reason):
                inputError = nil
                ytDlpError = reason
            }
        }
    }

    private func autoPasteFromClipboard() {
        if text.isEmpty, let prefill = vm.addSheetPrefill {
            vm.addSheetPrefill = nil
            text = prefill
            return
        }
        guard text.isEmpty,
              let prefill = AddSheetInput.clipboardPrefill(NSPasteboard.general.string(forType: .string))
        else { return }
        text = prefill
        pastedText = prefill
    }

    private func continueTapped() {
        let sources = vm.parsedSources(in: text)
        guard !sources.isEmpty else {
            inputError = L10n.t("Enter a valid URL, magnet, or .m3u8 link.")
            return
        }
        if sources.count > 1 {
            vm.add(rawLines: text, saveDirectory: resolvedSaveDirectory, priority: priority)
            dismiss()
            return
        }
        guard let line = firstParseableLine() else {
            inputError = L10n.t("Enter a valid URL, magnet, or .m3u8 link.")
            return
        }
        resetPerLinkFields()
        // Without the checklist a playlist link resolves to one video and silently drops the rest.
        if YtDlpResolver.isAvailable,
           PlaylistExpander.looksLikePlaylist(line),
           let url = URL(string: line) {
            phase = .playlist(url)
            return
        }
        resolveSingle(line)
    }

    /// Reset every per-link field: state left from the previous link would silently apply to this one.
    private func resetPerLinkFields() {
        checksumText = ""
        mirrorsText = ""
        chosenFormat = nil
        resolvedPageURL = nil
        ytDlpError = nil
    }

    /// The ordinary one-link path: preview it, then confirm. `keepFields` is for Try again,
    /// which must not throw away a checksum or mirrors the user already typed.
    private func resolveSingle(_ line: String, keepFields: Bool = false) {
        if !keepFields { resetPerLinkFields() }
        resolveTask?.cancel()
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
                // Only a line that doesn't parse comes back empty; network failures return a
                // preview whose note carries the reason, shown on the confirm step.
                phase = .input
                inputError = L10n.t("Enter a valid URL, magnet, or .m3u8 link.")
            }
        }
    }

    private var startOptions: [Dropdown<String>.Item] {
        [.option("now", L10n.t("Now"))]
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
        ytDlpError = nil
        resolveTask?.cancel()
        isResolvingMedia = true
        resolveTask = Task { @MainActor in
            defer { if !Task.isCancelled { isResolvingMedia = false } }
            let outcome = await YtDlpResolver.resolveMedia(pageURL, formatSelector: formatSelector)
            if Task.isCancelled { return }
            // The reason (quarantined binary, timeout, the page's own error) is the useful part.
            guard case .resolved(let resolved) = outcome,
                  let mediaPreview = YtDlpResolver.preview(for: resolved) else {
                if case .failed(let reason) = outcome {
                    ytDlpError = reason
                } else if case .resolved = outcome {
                    ytDlpError = L10n.t("yt-dlp couldn’t resolve that page")
                }
                return
            }

            guard !Task.isCancelled else { return }
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
                   cookieHost: previewHost(preview), inlineLoginLine: firstParseableLine())
        fetchSubtitlesIfWanted(for: preview)
        dismiss()
    }

    /// The inner Task is untracked on purpose: the sheet closes next line, yt-dlp's watchdog bounds it.
    private func fetchSubtitlesIfWanted(for preview: DownloadPreview) {
        guard vm.settings.subtitleDownloadEnabled, let pageURL = resolvedPageURL else { return }
        guard let directory = subtitleDestination else {
            vm.toastNow(L10n.t("Subtitles skipped — pick a folder under “Save to” so they land beside the video"))
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
                vm.toastNow(n == 1 ? L10n.t("Downloaded %d subtitle file", n) : L10n.t("Downloaded %d subtitle files", n))
            case .none:
                break
            case .failed(let msg):
                vm.toastNow(L10n.t("Subtitles: %@", msg))
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
        // The raw line, not the parsed locator: an inline `user:pass@` must reach the add path,
        // which moves it to the Keychain before the parser strips it.
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .lazy
            .flatMap { BatchExpander.expand($0) }
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
            // Same split as the main window and the drop basket; links land in the editor here
            // so they get the usual preview, while local torrents queue straight away.
            let plan = InboundDrop.plan(for: urls)
            guard !plan.isEmpty else { return }
            if !plan.links.isEmpty {
                appendLines(plan.links.map(\.absoluteString))
            }
            if let message = InboundDrop.unsupportedMessage(for: plan.unsupportedFiles) {
                inputError = message
            }
            guard !plan.torrentFiles.isEmpty else { return }
            Task { @MainActor in
                InboundDrop.queueTorrentFiles(plan.torrentFiles)
                if plan.links.isEmpty && plan.unsupportedFiles.isEmpty { dismiss() }
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
            return preview.isEstimatedSize ? L10n.t("Size resolved while downloading") : L10n.t("Unknown size")
        }
        return (preview.isEstimatedSize ? "~" : "") + bytes.byteString
    }
}
