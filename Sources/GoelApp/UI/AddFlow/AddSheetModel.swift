import SwiftUI
import AppKit
import GoelCore

/// Everything the Add sheet remembers between its steps, and the decisions behind them. The old
/// sheet kept this in `@State`; it lives here so each step can be its own view and file. The views
/// draw it; nothing here is persisted.
@MainActor
final class AddSheetModel: ObservableObject {
    enum Phase: Equatable {
        case input
        case resolving
        case confirm(DownloadPreview)
        case playlist(URL)
        /// Several links: the shared "Review N links" step.
        case review(String)
    }

    enum SaveOption {
        static let automatic = "automatic"
        static let choose = "__choose__"
    }

    let vm: AppViewModel
    let capturedCookies: String?
    /// Closes the sheet; the view installs its `dismiss` here.
    var finish: () -> Void = {}

    @Published var phase: Phase = .input
    @Published var deselectedFileIDs: Set<Int> = []
    @Published var text = "" {
        didSet { if text != oldValue { inputError = nil } }
    }
    @Published var priority: FilePriority = .normal
    @Published var checksumText = ""
    @Published var mirrorsText = ""
    @Published var isResolvingMedia = false
    @Published var inputError: String?
    var resolveTask: Task<Void, Never>?
    @Published var resolvedPageURL: URL?
    /// Shown under the yt-dlp row: a toast would draw in the main window, behind this sheet.
    @Published var ytDlpError: String?
    /// The text the clipboard put in the box; the "Pasted from clipboard" note shows while it's unchanged.
    @Published var pastedText: String?
    @Published var showAdvanced = false
    /// Latched from ``AppViewModel/addSheetRevealsAdvanced`` when the sheet opens.
    private var revealAdvanced = false

    @Published var cookieSource: CookieSource = .none
    /// A live bearer credential: in memory only, never `@AppStorage` or any other store.
    @Published var pastedCookies = ""

    @Published var chosenFormat: MediaFormat?
    @Published var pageListsFormats = false
    /// Media mode's one-click choice; a raw format from "More formats…" clears it.
    @Published var mediaPreset: MediaPreset? = .best
    @Published var whenDone = WhenDone.nothing
    /// The name typed over the suggested one, extension excluded; nil keeps the suggestion.
    @Published var editedBaseName: String?

    @Published var startSelection = StartPicker.now

    /// Starts on the user's own rule (nil folder): a hard-coded ~/Downloads here used to override
    /// "Sort by type" from onboarding for every download added through this sheet.
    @Published var saveSelection = SaveOption.automatic
    var previousSaveSelection = SaveOption.automatic
    @Published var customFolder: String?

    /// Free space on the chosen folder's volume; refreshed when the folder changes, not per frame.
    @Published var freeBytes: Int64?

    // Snapshot seams: set only by the DEBUG snapshot entries, nil/true in the app.
    var refreshesFreeSpace = true
    var mediaListingSeed: AddListingSeed<[MediaFormat]>?
    var playlistSeed: AddListingSeed<PlaylistExpansion>?
    var reviewSeed: [LinkReviewItem]?

    init(vm: AppViewModel, capturedCookies: String?) {
        self.vm = vm
        self.capturedCookies = capturedCookies
    }

    // MARK: Labels

    var headerSymbol: String { phase == .input ? "link" : "checklist" }

    func reviewTitle(_ lines: String) -> String {
        L10n.t("Review %d links", Set(vm.parsedSources(in: lines).map(\.dedupKey)).count)
    }

    /// What the input step recognised so far, one per distinct link.
    var recognizedSources: [DownloadSource] {
        var seen = Set<String>()
        return vm.parsedSources(in: text).filter { seen.insert($0.dedupKey).inserted }
    }

    private var downloadsPath: String { ("~/Downloads" as NSString).expandingTildeInPath }
    private var moviesPath: String { ("~/Movies" as NSString).expandingTildeInPath }

    var saveOptions: [Dropdown<String>.Item] {
        var options: [Dropdown<String>.Item] = [
            .option(SaveOption.automatic, defaultFolderLabel),
            .separator,
            .option(downloadsPath, "~/Downloads"),
            .option(moviesPath, "~/Movies"),
        ]
        let extra = SaveFolderPicker.extraFolders(recent: RecentFolders.load(), current: customFolder,
                                                  fixed: [downloadsPath, moviesPath])
        options += extra.map { .option($0, ($0 as NSString).abbreviatingWithTildeInPath) }
        options.append(.separator)
        options.append(.option(SaveOption.choose, L10n.t("Choose folder…")))
        return options
    }

    /// Names the rule Settings › General sets, so "Default" never hides where files will land.
    var defaultFolderLabel: String {
        switch vm.settings.defaultFolderRule {
        case "byType", "automatic": return L10n.t("Default: sorted by type")
        case "bySource": return L10n.t("Default: sorted by source")
        default:
            return L10n.t("Default: %@",
                          (vm.settings.defaultSaveDirectory as NSString).abbreviatingWithTildeInPath)
        }
    }

    func advancedSummary(_ preview: DownloadPreview) -> String {
        // Only what the advanced group shows: mirrors for HTTP alone, no checksum for a torrent.
        switch preview.kind {
        case .http: return L10n.t("checksum, mirrors, cookies")
        case .torrent: return L10n.t("cookies")
        case .hls, .ftp, .sftp: return L10n.t("checksum, cookies")
        }
    }

    func sizeText(_ preview: DownloadPreview) -> String {
        guard let bytes = preview.totalBytes else {
            return preview.isEstimatedSize ? L10n.t("Size resolved while downloading") : L10n.t("Unknown size")
        }
        return (preview.isEstimatedSize ? "~" : "") + bytes.byteString
    }

    // MARK: Opening

    /// A handed-over page already said what it wants; go straight to resolving its formats. Also
    /// runs when a page arrives while the sheet is open on its first step: it replaces what was there.
    func consumePrefill() {
        guard let prefill = vm.addSheetPrefill, phase == .input else { return }
        vm.addSheetPrefill = nil
        text = prefill
        pastedText = nil
        DispatchQueue.main.async { [weak self] in self?.continueTapped() }
    }

    func autoPasteFromClipboard() {
        if vm.addSheetRevealsAdvanced {
            vm.addSheetRevealsAdvanced = false
            revealAdvanced = true
        }
        if text.isEmpty, vm.addSheetPrefill != nil {
            consumePrefill()
            return
        }
        guard text.isEmpty,
              let prefill = AddSheetInput.clipboardPrefill(NSPasteboard.general.string(forType: .string))
        else { return }
        text = prefill
        pastedText = prefill
    }

    func clearPasted() {
        text = ""
        pastedText = nil
    }

    // MARK: Input → confirm

    func continueTapped() {
        let sources = vm.parsedSources(in: text)
        guard !sources.isEmpty else {
            inputError = L10n.t("Enter a valid URL, magnet, or .m3u8 link.")
            return
        }
        if sources.count > 1 {
            phase = .review(text)
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
        pageListsFormats = false
        mediaPreset = .best
        editedBaseName = nil
        resolvedPageURL = nil
        ytDlpError = nil
    }

    /// The ordinary one-link path: preview it, then confirm. `keepFields` is for Try again,
    /// which must not throw away a checksum or mirrors the user already typed.
    func resolveSingle(_ line: String, keepFields: Bool = false) {
        if !keepFields { resetPerLinkFields() }
        resolveTask?.cancel()
        phase = .resolving
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
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

    func retryResolve() {
        if let line = firstParseableLine() { resolveSingle(line, keepFields: true) }
    }

    func resolveSingleVideo() {
        if let line = firstParseableLine() { resolveSingle(line) }
    }

    func cancelResolving() {
        resolveTask?.cancel()
        phase = .input
    }

    func cancelResolve() { resolveTask?.cancel() }

    func continueWithoutPreview() {
        resolveTask?.cancel()
        if let line = firstParseableLine() {
            vm.add(rawLines: line, saveDirectory: resolvedSaveDirectory, priority: priority)
        }
        finish()
    }

    /// Back from the confirm step: a yt-dlp resolve still running would otherwise flip the phase
    /// or commit the download after the user left.
    func goBack() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolvingMedia = false
        deselectedFileIDs = []
        ytDlpError = nil
        phase = .input
    }

    func confirmAppeared() {
        showAdvanced = revealAdvanced || AddSheetInput.advancedHasContent(
            checksum: checksumText, mirrors: mirrorsText, cookieSource: cookieSource,
            hasCapturedCookies: capturedCookies != nil)
    }

    func addPlaylist(_ items: [PlaylistItem], preset: MediaPreset?) {
        vm.addPlaylist(items, preset: preset, saveDirectory: resolvedSaveDirectory, priority: priority)
        finish()
    }
}
