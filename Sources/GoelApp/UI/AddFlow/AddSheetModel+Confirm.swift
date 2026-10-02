import SwiftUI
import AppKit
import GoelCore

/// A listing a picker would otherwise ask yt-dlp for. The snapshot harness hands one in so the
/// pickers show a state without spawning anything; the app always passes nil.
enum AddListingSeed<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

/// The confirm step's decisions: what to warn about, where it lands, and the commit itself.
extension AddSheetModel {

    /// The reason the preview came back empty, for links whose server answered badly or not at all.
    /// A torrent without peers yet and a yt-dlp stream keep their plain informational note.
    func unreachableMessage(_ preview: DownloadPreview) -> String? {
        guard resolvedPageURL == nil, let note = preview.note else { return nil }
        switch preview.kind {
        case .http, .ftp, .sftp:
            return AddSheetInput.resolveFailureMessage(host: previewHost(preview), reason: note,
                                                       isGenericUnreachable: preview.noteIsGenericUnreachable)
        case .torrent, .hls:
            return nil
        }
    }

    /// The folder whose volume the space check asks about: the one "Automatic" really resolves
    /// to for this download (a `Video` subfolder may be a link onto another disk).
    func diskSpaceFolder(for preview: DownloadPreview) -> String {
        DiskSpaceCheck.folder(chosen: resolvedSaveDirectory, for: preview.source,
                              suggestedName: preview.suggestedName, settings: vm.settings)
    }

    func refreshFreeSpace(in folder: String) async {
        guard refreshesFreeSpace else { return }
        let free = await Task.detached(priority: .userInitiated) {
            DiskSpaceCheck.availableCapacity(forFolder: folder)
        }.value
        if !Task.isCancelled { freeBytes = free }
    }

    /// Bytes this preview will write: for a torrent, only the files still ticked.
    func neededBytes(_ preview: DownloadPreview) -> Int64? {
        if preview.kind == .torrent, !preview.files.isEmpty {
            let wanted = preview.files.filter { !deselectedFileIDs.contains($0.id) }
            return wanted.reduce(Int64(0)) { $0 + $1.length }
        }
        return preview.totalBytes
    }

    func diskVerdict(_ preview: DownloadPreview) -> DiskSpaceCheck.Verdict? {
        DiskSpaceCheck.verdict(needed: neededBytes(preview), available: freeBytes)
    }

    func allFilesDeselected(_ preview: DownloadPreview) -> Bool {
        preview.kind == .torrent
            && !preview.files.isEmpty
            && deselectedFileIDs.isSuperset(of: Set(preview.files.map(\.id)))
    }

    func existingFileWarning(_ preview: DownloadPreview) -> String? {
        FileNameEdit.existingFileWarning(name: finalName(preview), in: diskSpaceFolder(for: preview),
                                         reaction: vm.settings.existingFileReaction)
    }

    func duplicateMessage(_ preview: DownloadPreview) -> String? {
        guard let duplicate = vm.existingDuplicate(of: preview.source) else { return nil }
        return L10n.t("Already in your list (%@) — starting it again won’t add a second copy.",
                      L10n.midSentence(L10n.t(duplicate.status.displayName)))
    }

    /// A torrent has no checksum, mirror or per-host cookie to offer.
    func showsAdvanced(_ preview: DownloadPreview) -> Bool {
        preview.kind != .torrent || previewHost(preview) != nil
    }

    /// The yt-dlp section is for an HTTP link while yt-dlp is installed (or a snapshot seeds it).
    func offersMedia(_ preview: DownloadPreview) -> Bool {
        preview.kind == .http && (YtDlpResolver.isAvailable || mediaListingSeed != nil)
    }

    /// The preset picker spawns `yt-dlp -F` just by appearing, so mount it only for a video *page*.
    func mediaPageURL(_ preview: DownloadPreview) -> URL? {
        guard case .url(let pageURL) = preview.source,
              !preview.source.looksLikeDownloadableFile,
              resolvedPageURL == nil else { return nil }
        return pageURL
    }

    // MARK: Save to

    var resolvedSaveDirectory: String? {
        switch saveSelection {
        case SaveOption.automatic, SaveOption.choose: return nil
        default: return saveSelection
        }
    }

    func handleSaveSelection(_ newValue: String) {
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

    func chooseAnotherFolder() {
        saveSelection = SaveOption.choose
        handleSaveSelection(SaveOption.choose)
    }

    // MARK: Name

    func nameBinding(_ preview: DownloadPreview) -> Binding<String> {
        Binding(get: { [weak self] in self?.editedBaseName ?? FileNameEdit.split(preview.suggestedName).base },
                set: { [weak self] in self?.editedBaseName = $0 })
    }

    /// The suggested name with the typed base; the extension never changes.
    func finalName(_ preview: DownloadPreview) -> String {
        FileNameEdit.name(base: editedBaseName, original: preview.suggestedName)
    }

    // MARK: Start

    /// A video page must be resolved through yt-dlp first, or its HTML gets queued. That holds for
    /// "Best available" too (no format picked, no `-f`) once yt-dlp has listed formats for the page.
    func start(_ preview: DownloadPreview) {
        if resolvedPageURL == nil, case .url = preview.source, chosenFormat != nil || pageListsFormats {
            resolveThenCommit(preview, formatSelector: chosenFormat?.id
                ?? mediaPreset?.formatSelector(maxHeight: vm.settings.hlsMaxHeight))
        } else {
            commit(preview)
        }
    }

    private func resolveThenCommit(_ preview: DownloadPreview, formatSelector: String?) {
        guard case .url(let pageURL) = preview.source else { return commit(preview) }
        ytDlpError = nil
        cancelResolve()
        isResolvingMedia = true
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
        let startAt = StartPicker.date(for: startSelection)
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
                   cookieHost: previewHost(preview), inlineLoginLine: firstParseableLine(),
                   name: preview.kind == .torrent ? nil : finalName(preview),
                   whenDone: whenDone.isActionable ? whenDone : nil,
                   onAdded: chainAudio)
        fetchSubtitlesIfWanted(for: preview)
        finish()
    }

    /// The inner Task is untracked on purpose: the sheet closes next line, yt-dlp's watchdog bounds it.
    private func fetchSubtitlesIfWanted(for preview: DownloadPreview) {
        guard vm.settings.subtitleDownloadEnabled, let pageURL = resolvedPageURL else { return }
        let directory = DiskSpaceCheck.folder(chosen: resolvedSaveDirectory, for: preview.source,
                                              suggestedName: preview.suggestedName, settings: vm.settings)
        let base = (preview.suggestedName as NSString).deletingPathExtension
        let langs = vm.settings.subtitleLanguages
        let auto = vm.settings.subtitleIncludeAutoGenerated
        let vm = self.vm
        Task { @MainActor in
            let outcome = await YtDlpResolver.downloadSubtitles(
                pageURL: pageURL, into: directory, baseName: base,
                languages: langs, includeAuto: auto)
            switch outcome {
            case .downloaded(let n):
                vm.toastSuccess(n == 1 ? L10n.t("Downloaded %d subtitle file", n) : L10n.t("Downloaded %d subtitle files", n))
            case .none:
                break
            case .failed(let msg):
                vm.toastError(L10n.t("Subtitles: %@", msg))
            }
        }
    }

    /// Callers must never read ``pastedCookies`` directly — only this sanitised value leaves the sheet.
    var cookieHeaderToAttach: String? {
        switch cookieSource {
        case .none:    return nil
        case .browser: return capturedCookies.flatMap(CookieHeader.sanitized)
        case .manual:  return CookieHeader.sanitized(pastedCookies)
        }
    }

    func previewHost(_ preview: DownloadPreview) -> String? {
        switch preview.source {
        case .url(let url), .hlsStream(let url): return url.host
        case .magnet, .torrentFile: return nil
        }
    }

    func firstParseableLine() -> String? {
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

    /// Audio presets queue Extract Audio for when the download finishes.
    private var chainAudio: ((DownloadTask.ID) -> Void)? {
        guard chosenFormat == nil, resolvedPageURL != nil || pageListsFormats,
              let format = mediaPreset?.chainedAudio else { return nil }
        let jobs = vm.mediaJobs
        return { id in jobs.chainedAudio[id] = format }
    }

    // MARK: Drop

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // `collectDroppedURLs` calls back on the main queue.
        collectDroppedURLs(providers) { [weak self] urls in
            MainActor.assumeIsolated { self?.applyDrop(urls) }
        }
    }

    private func applyDrop(_ urls: [URL]) {
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
            if plan.links.isEmpty && plan.unsupportedFiles.isEmpty { self.finish() }
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
}
