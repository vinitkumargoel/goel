import CoreTransferable
import Foundation
import OSLog
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Path safety

/// Interactive-input guard in front of ``FileStore``.
///
/// `FileStore` is the app's single save-path resolver — `destinationURL(filename:subdirectory:)`
/// is what turns a `Download` into a URL, here and in the engine, and this file never reimplements
/// it. What `FileStore` deliberately does *not* do is **refuse**: it sanitises, because an engine
/// handed a hostile `Content-Disposition` must still produce a working download rather than fail.
///
/// A person typing a folder name is the opposite case. Silently turning `../../Library` into a
/// folder called `Library` is worse than saying no, so the Library's create and rename paths come
/// through here first, and only then reach the filesystem.
///
/// Containment itself is *not* reimplemented: ``isContained(_:within:)`` forwards to
/// `FileStore.isContained` and only widens it to treat the root as inside itself, because the
/// Folders tab starts at the root.
///
/// `Documents/` specifically, never Application Support and never `tmp`: `UIFileSharingEnabled`
/// and `LSSupportsOpeningDocumentsInPlace` expose exactly `Documents/`, and PRD §4.2 makes that
/// visibility the feature.
enum LibraryPathSafety {

    /// Why a path was refused. Each case has copy a user can act on — "Something went wrong" is
    /// banned by the PRD's honest-failure principle.
    enum PathError: Error, LocalizedError, Equatable {
        case emptyName
        case invalidCharacters
        case escapesContainer
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                "A name is required."
            case .invalidCharacters:
                "Names can't contain “/”, “:”, or “..”."
            case .escapesContainer:
                "That location is outside the Goel° folder."
            case let .alreadyExists(name):
                "“\(name)” already exists here."
            }
        }
    }

    /// The app's one file store. Every save path the Library shows comes out of this value.
    static let store = FileStore()

    /// The container root. Everything the Library shows or writes lives under this URL.
    static var documentsURL: URL { store.root }

    /// Characters that may never appear in a name the user typed. `/` and NUL are the ones the
    /// filesystem itself would misread; `:` is rewritten to `/` by the Finder and by Files, which
    /// makes it a traversal vector by a slower route.
    private static let forbiddenSubstrings = ["/", "\\", ":", "..", "\0", "\u{2044}"]

    /// Is `url` at or beneath `root`?
    ///
    /// Forwards to `FileStore.isContained`, which is the app's audited component-wise check, and
    /// widens it by one case: `FileStore` requires *strictly* inside, while the Folders tab needs
    /// the root itself to count as a legal location to stand in.
    static func isContained(_ url: URL, within root: URL) -> Bool {
        if canonicalComponents(url) == canonicalComponents(root) { return true }
        return FileStore.isContained(url, in: root)
    }

    /// A single path component the user typed — a new folder, or a rename.
    ///
    /// Returns the trimmed name, or throws. Nothing else in the app is allowed to build a
    /// component from user input.
    static func validatedComponent(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PathError.emptyName }
        guard trimmed != ".", trimmed != ".." else { throw PathError.invalidCharacters }
        for fragment in forbiddenSubstrings where trimmed.contains(fragment) {
            throw PathError.invalidCharacters
        }
        // A leading dot hides the file from Files and from our own scans — refuse it rather than
        // silently creating a folder the user can never see again.
        guard !trimmed.hasPrefix(".") else { throw PathError.invalidCharacters }
        return trimmed
    }

    /// Resolves a container-relative *folder* path to an absolute URL, or throws.
    ///
    /// This is the refusing counterpart to `FileStore.destinationURL`, not a second copy of it:
    /// it is reached only from folder navigation, creation and rename, where the input is
    /// something a person typed or something the Folders tab is standing on. File destinations —
    /// the actual save paths — never come through here.
    ///
    /// An absolute input is *not* a shortcut: `URL(fileURLWithPath:relativeTo:)` ignores the base
    /// for an absolute path, so it lands outside the container and the containment check refuses
    /// it. That is the intended behaviour, not an accident of the implementation.
    static func resolve(_ relativePath: String, within root: URL = documentsURL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PathError.emptyName }
        guard !trimmed.contains("\0") else { throw PathError.invalidCharacters }

        let candidate = URL(fileURLWithPath: trimmed, relativeTo: root).standardizedFileURL
        guard isContained(candidate, within: root) else { throw PathError.escapesContainer }
        return candidate
    }

    /// Where a completed download's bytes actually are — resolved by ``FileStore``, never here.
    ///
    /// `Download.saveDirectory` is *either* a container-relative path (the fixtures write
    /// `"Goel°/Apps"`) *or* the absolute directory `AppModel` wrote back on completion.
    /// `FileStore.destinationURL` already handles all three shapes, including an absolute path
    /// left over from a different install, which it ignores rather than honours.
    static func downloadURL(_ download: Download) throws -> URL {
        try store.destinationURL(
            filename: download.filename,
            subdirectory: download.saveDirectory.isEmpty ? nil : download.saveDirectory
        )
    }

    /// `url` expressed relative to `root`, or `nil` when it is not inside it. Used as a stable
    /// identity for grid tiles and folder rows.
    static func relativePath(of url: URL, within root: URL = documentsURL) -> String? {
        guard isContained(url, within: root) else { return nil }
        let rootParts = canonicalComponents(root)
        let urlParts = canonicalComponents(url)
        return urlParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// Standardise, then resolve symlinks, then standardise again: `resolvingSymlinksInPath()`
    /// can reintroduce a `..` of its own on a path whose leading portion does not exist yet.
    private static func canonicalComponents(_ url: URL) -> [String] {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
    }
}

// MARK: - Export

/// A finished file, exported by reference.
///
/// `FileRepresentation` hands the system a URL rather than the bytes, which is the difference
/// between exporting a 12 GB backup and being killed for it. A `FileDocument` would have to load
/// the whole thing into memory first.
struct ExportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(file.url)
        }
    }
}

// MARK: - Library

/// The Library tab — and the app's answer to "there is no filesystem" (PRD §4.2).
///
/// Three views of the same container: **Recent** (what finished), **Folders** (where it is), and
/// **Media** (what it looks like). Everything on every tab can leave the app: a `ShareLink` from
/// any row's context menu or swipe, and a `.fileExporter` behind the row's trailing button so a
/// file can be copied into iCloud Drive or anywhere else the document picker reaches.
///
/// Nothing here writes a path itself. Every URL comes from ``LibraryPathSafety``.
public struct LibraryView: View {

    /// The segmented control's three cases, in mockup order.
    private enum Section: String, CaseIterable, Identifiable, Hashable {
        case recent, folders, media

        var id: Self { self }

        var title: String {
            switch self {
            case .recent: "Recent"
            case .folders: "Folders"
            case .media: "Media"
            }
        }
    }

    /// Values `Theme.Metric` does not carry, named here so no bare number appears in a view body —
    /// the same arrangement `DownloadRow` uses. Fold them into `Theme.swift` when it is next open.
    private enum Local {
        /// `.rname { margin-bottom: 5px }`, rounded to the row grid — matches `DownloadRow`.
        static let nameToSubtitle: CGFloat = 4
    }

    @Environment(AppModel.self) private var app

    @State private var section: Section = .recent
    @State private var editMode: EditMode = .inactive
    @State private var recentSelection: Set<UUID> = []
    @State private var mediaSelection: Set<String> = []

    // Folders
    @State private var folderPath: String = ""
    @State private var folderEntries: [FolderEntry] = []
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: FolderEntry?
    @State private var renameText = ""
    @State private var pendingFolderDeletion: FolderEntry?

    // Media
    @State private var mediaItems: [MediaItem] = []
    @State private var previewItem: MediaItem?

    // Export / share
    @State private var exportItem: ExportedFile?
    @State private var exportFilename = ""
    @State private var isExporting = false
    @State private var isConfirmingBulkDelete = false

    @State private var message: String?

    /// The card's copy is set at the row-title size in the frame — a hair larger than a row
    /// subtitle. `Theme.Typo` is fixed-point by design, so Dynamic Type comes from here.
    @ScaledMetric(relativeTo: .subheadline) private var cardTextSize = Theme.Typo.Size.rowTitle

    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "library")

    public init() {}

    public var body: some View {
        @Bindable var app = app

        NavigationStack(path: $app.libraryPath) {
            VStack(spacing: 0) {
                sectionPicker
                content
            }
            .background(Theme.Color.ground.ignoresSafeArea())
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { id in
                if let download = app.store[id] {
                    LibraryFileDetail(download: download)
                } else {
                    ContentUnavailableView(
                        "That file is gone",
                        systemImage: "questionmark.folder",
                        description: Text("It was removed from the Library.")
                    )
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task(id: section) { await refresh() }
        .task(id: folderPath) { await loadFolder() }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
                .textInputAutocapitalization(.words)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Folders appear in the Files app too.")
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert(
            "Delete “\(pendingFolderDeletion?.name ?? "")”?",
            isPresented: folderDeletionBinding
        ) {
            Button("Delete", role: .destructive) { commitFolderDeletion() }
            Button("Cancel", role: .cancel) { pendingFolderDeletion = nil }
        } message: {
            Text("This also removes it from the Files app. It can't be undone.")
        }
        .confirmationDialog(
            "Delete \(recentSelection.count) file\(recentSelection.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't do that", isPresented: messageBinding) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportItem,
            contentTypes: [.data],
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                message = error.localizedDescription
            }
            exportItem = nil
        }
        .sheet(item: $previewItem) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
    }

    // MARK: - Chrome

    private var sectionPicker: some View {
        Picker("Library section", selection: $section) {
            ForEach(Section.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, Theme.Metric.rowVerticalPadding)
        .padding(.bottom, Theme.Metric.gutter)
        .accessibilityLabel("Library section")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if section == .folders {
                Button {
                    newFolderName = ""
                    isCreatingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
            } else {
                // An `EditButton` in everything but name: the mockup's label is "Select", and
                // "Edit" would promise renaming that this list does not offer.
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation {
                        if editMode.isEditing {
                            editMode = .inactive
                            recentSelection.removeAll()
                            mediaSelection.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                }
                .fontWeight(editMode.isEditing ? .semibold : .regular)
            }
        }

        if editMode.isEditing, !selectedURLs.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(items: selectedURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Text("\(selectedURLs.count) selected")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Color.label2)
                    .monospacedDigit()
                Spacer()
                Button(role: .destructive) {
                    isConfirmingBulkDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Theme.Color.danger)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .recent: recentList
        case .folders: folderList
        case .media: mediaTab
        }
    }

    // MARK: - Recent

    /// Newest completion first — the mockup reads Today, Yesterday, 2 days ago.
    private var recentItems: [Download] {
        app.store.completedDownloads.sorted {
            ($0.completedAt ?? $0.addedAt) > ($1.completedAt ?? $1.addedAt)
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if recentItems.isEmpty {
            // The card stays even with nothing to list: an empty Library is exactly when a user
            // wonders where their downloads are going to end up.
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label("Nothing finished yet", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("Completed downloads land here — and in the Files app, under Goel°. Start one from the Downloads tab.")
                }
                .frame(maxHeight: .infinity)

                filesCard
                    .padding(.horizontal, Theme.Metric.gutter)
                    .padding(.bottom, Theme.Metric.gutter)
            }
            .background(Theme.Color.ground)
        } else {
            List(selection: $recentSelection) {
                ForEach(recentItems) { download in
                    recentRow(download)
                        .tag(download.id)
                }

                filesCard
                    .listRowInsets(EdgeInsets(
                        top: Theme.Metric.gutter,
                        leading: Theme.Metric.gutter,
                        bottom: Theme.Metric.gutter,
                        trailing: Theme.Metric.gutter
                    ))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Color.ground)
        }
    }

    @ViewBuilder
    private func recentRow(_ download: Download) -> some View {
        let row = DownloadRow(download: download, style: .library) {
            beginExport(download)
        }
        // The gutter is padding on the row rather than a `listRowInset`, so the row's leading
        // edge stays at zero and the hairline runs edge to edge — which is what `frame7.png`
        // draws. A leading inset would give the inset separator iOS defaults to.
        .padding(.horizontal, Theme.Metric.gutter)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.Color.separator)
        .contextMenu { rowMenu(download) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { delete(download) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { beginExport(download) } label: {
                Label("Save to…", systemImage: "folder")
            }
            .tint(Theme.Color.instrument)
        }
        .swipeActions(edge: .leading) {
            if let url = url(for: download) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .tint(Theme.Color.ember)
            }
        }

        // In edit mode the list owns the tap, so the row must not also be a button.
        if editMode.isEditing {
            row
        } else {
            Button {
                app.libraryPath.append(download.id)
            } label: {
                row
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func rowMenu(_ download: Download) -> some View {
        if let url = url(for: download) {
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Button { beginExport(download) } label: {
            Label("Save to…", systemImage: "folder")
        }
        Button(role: .destructive) { delete(download) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// The mockup's informational card: `elev2` at ``Theme/Metric/cardRadius``.
    ///
    /// The fill is measured off `frame7.png` — `#E5E5EA` on the `#F2F2F7` ground, i.e. `elev2`,
    /// a card that sits *into* the page rather than floating above it. `elev1` would be pure
    /// white here and would read as another row.
    private var filesCard: some View {
        HStack(alignment: .top, spacing: Theme.Metric.rowVerticalPadding) {
            Image(systemName: "folder")
                .font(.system(size: Theme.Typo.Size.statValue, weight: .regular))
                .foregroundStyle(Theme.Color.instrument)
                .accessibilityHidden(true)

            (
                Text("Everything here also appears in the ")
                    + Text("Files").fontWeight(.semibold)
                    + Text(" app under Goel° — nothing is trapped inside this app.")
            )
            .font(.system(size: cardTextSize))
            .foregroundStyle(Theme.Color.label1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Metric.gutter)
        .background(
            Theme.Color.elev2,
            in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Folders

    @ViewBuilder
    private var folderList: some View {
        VStack(spacing: 0) {
            breadcrumb

            if folderEntries.isEmpty {
                ContentUnavailableView {
                    Label("This folder is empty", systemImage: "folder")
                } description: {
                    Text("Downloads you save here show up in the Files app under On My iPhone → Goel°.")
                } actions: {
                    Button("New Folder") {
                        newFolderName = ""
                        isCreatingFolder = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Color.ember)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(folderEntries) { entry in
                        folderRow(entry)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.Color.ground)
    }

    private var breadcrumb: some View {
        HStack(spacing: Theme.Metric.rowVerticalPadding) {
            if !folderPath.isEmpty {
                Button {
                    folderPath = folderPath.contains("/")
                        ? String(folderPath[..<(folderPath.lastIndex(of: "/") ?? folderPath.startIndex)])
                        : ""
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(
                            minWidth: Theme.Metric.minHitTarget,
                            minHeight: Theme.Metric.minHitTarget
                        )
                }
                .accessibilityLabel("Go up one folder")
            }

            Text(folderPath.isEmpty ? "Goel°" : "Goel°/\(folderPath)")
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Color.label2)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.bottom, Theme.Metric.rowVerticalPadding)
    }

    @ViewBuilder
    private func folderRow(_ entry: FolderEntry) -> some View {
        let row = HStack(spacing: Theme.Metric.rowVerticalPadding) {
            RoundedRectangle(cornerRadius: Theme.Metric.rowIconRadius, style: .continuous)
                .fill(Theme.Color.elev2)
                .frame(width: Theme.Metric.rowIcon, height: Theme.Metric.rowIcon)
                .overlay {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: Theme.Metric.rowIcon / 2, weight: .semibold))
                        .foregroundStyle(entry.isDirectory ? Theme.Color.instrument : Theme.Color.label2)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Local.nameToSubtitle) {
                Text(entry.name)
                    .font(Theme.Typo.rowTitle)
                    .foregroundStyle(Theme.Color.label1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(Theme.Typo.rowSubtitle)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.label2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.Typo.Size.sectionLabel, weight: .semibold))
                    .foregroundStyle(Theme.Color.label3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Metric.rowVerticalPadding)
        .padding(.horizontal, Theme.Metric.gutter)
        .contentShape(.rect)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.Color.separator)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingFolderDeletion = entry } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Theme.Color.instrument)
        }
        .contextMenu {
            if !entry.isDirectory {
                ShareLink(item: entry.url) { Label("Share…", systemImage: "square.and.arrow.up") }
                Button {
                    exportFilename = entry.name
                    exportItem = ExportedFile(url: entry.url)
                    isExporting = true
                } label: {
                    Label("Save to…", systemImage: "folder")
                }
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { pendingFolderDeletion = entry } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        if entry.isDirectory {
            Button {
                folderPath = folderPath.isEmpty ? entry.name : "\(folderPath)/\(entry.name)"
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaTab: some View {
        if mediaItems.isEmpty {
            ContentUnavailableView {
                Label("No photos or video yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Images and video you download appear here as thumbnails, and in the Files app under Goel°.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.ground)
        } else {
            MediaGrid(
                items: mediaItems,
                isSelecting: editMode.isEditing,
                selection: $mediaSelection
            ) { item in
                previewItem = item
            }
        }
    }

    // MARK: - Loading

    private func refresh() async {
        switch section {
        case .recent:
            break
        case .folders:
            await loadFolder()
        case .media:
            mediaItems = await MediaLibraryScanner.scan(root: LibraryPathSafety.documentsURL)
        }
    }

    private func loadFolder() async {
        let root = LibraryPathSafety.documentsURL
        let target: URL
        if folderPath.isEmpty {
            target = root
        } else if let resolved = try? LibraryPathSafety.resolve(folderPath, within: root) {
            target = resolved
        } else {
            folderPath = ""
            return
        }
        folderEntries = await FolderEntry.listing(at: target, root: root)
    }

    // MARK: - Actions

    /// The file a completed download actually produced, or `nil` when it cannot be resolved
    /// safely. Nothing in this view builds a URL any other way.
    private func url(for download: Download) -> URL? {
        try? LibraryPathSafety.downloadURL(download)
    }

    private var selectedURLs: [URL] {
        switch section {
        case .recent:
            recentItems.filter { recentSelection.contains($0.id) }.compactMap(url(for:))
        case .media:
            mediaItems.filter { mediaSelection.contains($0.id) }.map(\.url)
        case .folders:
            []
        }
    }

    private func beginExport(_ download: Download) {
        guard let url = url(for: download) else {
            message = LibraryPathSafety.PathError.escapesContainer.localizedDescription
            return
        }
        exportFilename = download.filename
        exportItem = ExportedFile(url: url)
        isExporting = true
    }

    private func delete(_ download: Download) {
        if let url = url(for: download) {
            try? FileManager.default.removeItem(at: url)
        }
        app.remove(download.id, deleteData: true)
    }

    private func deleteSelected() {
        switch section {
        case .recent:
            for download in recentItems where recentSelection.contains(download.id) {
                delete(download)
            }
            recentSelection.removeAll()
        case .media:
            for item in mediaItems where mediaSelection.contains(item.id) {
                guard LibraryPathSafety.isContained(item.url, within: LibraryPathSafety.documentsURL)
                else { continue }
                try? FileManager.default.removeItem(at: item.url)
            }
            mediaSelection.removeAll()
            Task { mediaItems = await MediaLibraryScanner.scan(root: LibraryPathSafety.documentsURL) }
        case .folders:
            break
        }
        withAnimation { editMode = .inactive }
    }

    private func createFolder() {
        do {
            let name = try LibraryPathSafety.validatedComponent(newFolderName)
            let relative = folderPath.isEmpty ? name : "\(folderPath)/\(name)"
            let url = try LibraryPathSafety.resolve(relative)
            guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw LibraryPathSafety.PathError.alreadyExists(name)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            newFolderName = ""
            Task { await loadFolder() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let entry = renameTarget else { return }
        renameTarget = nil
        do {
            let name = try LibraryPathSafety.validatedComponent(renameText)
            guard name != entry.name else { return }
            let relative = folderPath.isEmpty ? name : "\(folderPath)/\(name)"
            let destination = try LibraryPathSafety.resolve(relative)
            guard LibraryPathSafety.isContained(entry.url, within: LibraryPathSafety.documentsURL) else {
                throw LibraryPathSafety.PathError.escapesContainer
            }
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
                throw LibraryPathSafety.PathError.alreadyExists(name)
            }
            try FileManager.default.moveItem(at: entry.url, to: destination)
            Task { await loadFolder() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func commitFolderDeletion() {
        guard let entry = pendingFolderDeletion else { return }
        pendingFolderDeletion = nil
        guard LibraryPathSafety.isContained(entry.url, within: LibraryPathSafety.documentsURL) else {
            message = LibraryPathSafety.PathError.escapesContainer.localizedDescription
            return
        }
        do {
            try FileManager.default.removeItem(at: entry.url)
            Task { await loadFolder() }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Alert plumbing

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(get: { pendingFolderDeletion != nil }, set: { if !$0 { pendingFolderDeletion = nil } })
    }
}

// MARK: - Folder entry

/// One row of the Folders tab.
struct FolderEntry: Identifiable, Hashable, Sendable {
    var id: String
    var url: URL
    var name: String
    var isDirectory: Bool
    var byteCount: Int64
    var childCount: Int
    var modifiedAt: Date

    var subtitle: String {
        if isDirectory {
            let items = childCount == 1 ? "1 item" : "\(childCount) items"
            return "\(items) · \(Fmt.relative(modifiedAt))"
        }
        return "\(Fmt.bytes(byteCount)) · \(Fmt.relative(modifiedAt))"
    }

    /// A single directory level, folders first, then files, each alphabetical.
    ///
    /// Off the main actor: a container with a few thousand files takes long enough to stat that
    /// doing it inline drops frames on a tab switch.
    static func listing(at url: URL, root: URL) async -> [FolderEntry] {
        await Task.detached(priority: .userInitiated) { () -> [FolderEntry] in
            guard LibraryPathSafety.isContained(url, within: root) else { return [] }
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ]
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let entries = contents.compactMap { child -> FolderEntry? in
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return nil }
                let isDirectory = values.isDirectory ?? false
                // A directory's child count is one `contentsOfDirectory` per row. Acceptable at a
                // single level; it is exactly why the walk is not recursive.
                let children = isDirectory
                    ? (try? FileManager.default.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ).count) ?? 0
                    : 0
                return FolderEntry(
                    id: LibraryPathSafety.relativePath(of: child, within: root) ?? child.lastPathComponent,
                    url: child,
                    name: child.lastPathComponent,
                    isDirectory: isDirectory,
                    byteCount: Int64(values.fileSize ?? 0),
                    childCount: children,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            }

            return entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }.value
    }
}

// MARK: - File detail

/// Where a Recent row leads: what the file is, and every way to get it out of the app.
private struct LibraryFileDetail: View {
    let download: Download

    @State private var isExporting = false
    @State private var exportItem: ExportedFile?

    private var url: URL? {
        try? LibraryPathSafety.downloadURL(download)
    }

    var body: some View {
        List {
            SwiftUI.Section {
                LabeledContent("Size", value: Fmt.bytes(download.totalBytes ?? download.receivedBytes))
                LabeledContent("Source", value: download.sourceHost)
                LabeledContent(
                    "Finished",
                    value: download.completedAt.map { Fmt.relative($0) } ?? Fmt.placeholder
                )
                LabeledContent(
                    "Checksum",
                    value: download.checksumVerified ? "SHA-256 verified" : "Not verified"
                )
                if let relative = url.flatMap({ LibraryPathSafety.relativePath(of: $0) }) {
                    LabeledContent("In Files", value: "Goel°/\(relative)")
                }
            } header: {
                Text("File")
                    .font(Theme.Typo.sectionLabel)
                    .tracking(Theme.Typo.sectionTracking)
            }
            .monospacedDigit()

            SwiftUI.Section {
                if let url {
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        exportItem = ExportedFile(url: url)
                        isExporting = true
                    } label: {
                        Label("Save to…", systemImage: "folder")
                    }
                } else {
                    Text("This file is no longer inside the Goel° folder.")
                        .font(Theme.Typo.rowSubtitle)
                        .foregroundStyle(Theme.Color.label2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.ground)
        .navigationTitle(download.filename)
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            item: exportItem,
            contentTypes: [.data],
            defaultFilename: download.filename
        ) { _ in
            exportItem = nil
        }
    }
}

// MARK: - QuickLook

/// The system preview, for the Media grid. QuickLook renders video, images and PDFs without the
/// app carrying a renderer for each.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Previews

#Preview("Library · light") {
    let model = AppModel(
        engine: PreviewTransferEngine.makeStatic(),
        store: {
            let store = DownloadStore(persistenceURL: nil)
            store.replaceAll(PreviewTransferEngine.fixtures())
            return store
        }()
    )
    return LibraryView()
        .environment(model)
        .preferredColorScheme(.light)
}

#Preview("Library · dark") {
    let model = AppModel(
        engine: PreviewTransferEngine.makeStatic(),
        store: {
            let store = DownloadStore(persistenceURL: nil)
            store.replaceAll(PreviewTransferEngine.fixtures())
            return store
        }()
    )
    return LibraryView()
        .environment(model)
        .preferredColorScheme(.dark)
}
