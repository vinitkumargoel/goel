import SwiftUI
import UIKit

/// Frame 3 of `visual.html`: one decision, made with the facts already on screen.
///
/// The sheet's whole argument is that the metadata is resolved *before* the tap — name, exact
/// size, type and resumability — so nothing surprises the user at 99 %. Everything here follows
/// from that:
///
/// - The probe is inline and non-blocking. A spinner sits on the Size row; it never covers the
///   sheet and it never gates Add. A server that refuses a HEAD is an ordinary server.
/// - A link that cannot possibly work is rejected here, in words, rather than being accepted and
///   failed later. `file://` is refused for exactly the reason the desktop facade refuses it.
/// - A server with no `Accept-Ranges` is called out on the Type row *before* Add, because
///   "an interruption starts this over" is a fact worth knowing while you can still decide.
public struct AddSheet: View {

    // MARK: - Environment

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state

    @State private var link = ""
    @State private var name = ""
    /// Once the user touches Name, a late probe result must not overwrite their typing.
    @State private var nameWasEdited = false
    /// True while the code itself is writing `name` (probe result, provisional URL-derived name).
    /// The `name` change observer consumes and clears it so a programmatic write is not mistaken
    /// for a user keystroke — `focus == .name` alone can't tell them apart, because the Link
    /// field's `.onSubmit` parks focus on Name before the user types anything.
    @State private var isSettingNameProgrammatically = false
    @State private var saveDirectory = AddSheet.rootFolder
    @State private var wifiOnly = true
    @State private var startPaused = false

    /// Built in `.task`, because the engine only exists in the environment.
    @State private var probe: MetadataProbe?

    @FocusState private var focus: Field?

    private enum Field: Hashable { case link, name }

    // MARK: - Type scale
    //
    // `Font.system(size:)` does not scale on its own, so every fixed size from `visual.html` is
    // paired with `@ScaledMetric` over the matching `Theme.Typo.Size` value (CONVENTIONS).

    @ScaledMetric(relativeTo: .body) private var rowSize: CGFloat = Theme.Typo.Size.rowTitle
    @ScaledMetric(relativeTo: .footnote) private var monoSize: CGFloat = Theme.Typo.Size.rowSubtitle
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = Theme.Typo.Size.statValue
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = Theme.Typo.Size.caption

    // MARK: - Constants

    /// Downloads land in `Documents/Goel°/…`, which is what `PreviewTransferEngine` and the
    /// mockup's `Goel° › Linux` both assume.
    public static let rootFolder = "Goel°"

    /// The fallback when a link carries no usable last path component.
    static let fallbackFilename = "download"

    public init() {}

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    linkRow
                    validationRow
                    nameRow
                    sizeRow
                    typeRow
                    resumeNoticeRow
                    saveToRow
                    wifiRow
                    startPausedRow
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Color.elev1)
            .safeAreaInset(edge: .bottom, spacing: 0) { primaryButton }
            .navigationTitle("Add Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelAndDismiss() }
                }
                // The same commit as the bottom button, so the sheet stays usable with the
                // keyboard up even on the shortest detent.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(!canAdd)
                }
            }
        }
        .tint(Theme.Color.ember)
        // `.medium` is a hair too short for the eight rows: "Start paused" lands underneath the
        // bottom button and reads as missing. The mockup's sheet is a shade under two thirds.
        .presentationDetents([.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Color.elev1)
        .task { prepare() }
    }

    // MARK: - Rows

    private var linkRow: some View {
        field("Link") {
            TextField("https://example.com/file.iso", text: $link)
                .font(.system(size: monoSize, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Color.label1)
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .link)
                .onSubmit { focus = .name }
                .onChange(of: link) { _, new in linkChanged(new) }
                .accessibilityLabel("Link")
        }
    }

    @ViewBuilder
    private var validationRow: some View {
        if let message = validation.message {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Spacer(minLength: 0)
            }
            .font(.system(size: captionSize))
            .foregroundStyle(Theme.Color.danger)
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, Theme.Metric.rowVerticalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Link problem. \(message)")
            hairline
        }
    }

    private var nameRow: some View {
        field("Name") {
            TextField(probeFilename ?? Self.fallbackFilename, text: $name)
                .font(.system(size: rowSize))
                .foregroundStyle(Theme.Color.label1)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .name)
                .onSubmit { focus = nil }
                .onChange(of: name) { _, _ in
                    // A write the code made (probe result / provisional name) is not an edit,
                    // even though it can land while focus is already on this field.
                    if isSettingNameProgrammatically {
                        isSettingNameProgrammatically = false
                        return
                    }
                    // Only a deliberate edit counts; the probe filling it in does not.
                    if focus == .name { nameWasEdited = true }
                }
                .accessibilityLabel("Name")
        }
        // A probe that arrives after the user started typing must lose.
        .onChange(of: probeFilename) { _, resolved in
            guard let resolved, !resolved.isEmpty, !nameWasEdited, resolved != name else { return }
            isSettingNameProgrammatically = true
            name = resolved
        }
    }

    private var sizeRow: some View {
        field("Size") {
            HStack {
                if isProbing {
                    // Inline, on the one row that is actually waiting — never a blocking overlay.
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking the server")
                }
                Text(sizeText)
                    .font(.system(size: rowSize))
                    .monospacedDigit()
                    .foregroundStyle(sizeIsKnown ? Theme.Color.label1 : Theme.Color.label2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(isProbing ? "Checking the server" : sizeText)
        }
    }

    private var typeRow: some View {
        field("Type") {
            Text(typeText)
                .font(.system(size: rowSize))
                .foregroundStyle(typeIsKnown ? Theme.Color.label1 : Theme.Color.label2)
                .multilineTextAlignment(.trailing)
        }
    }

    /// PRD §4.1 — we say it up front rather than failing at 99 %.
    @ViewBuilder
    private var resumeNoticeRow: some View {
        if showsResumeNotice {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.clockwise.circle")
                Text("This server cannot resume an interrupted transfer, so a drop restarts it from the beginning.")
                Spacer(minLength: 0)
            }
            .font(.system(size: captionSize))
            .foregroundStyle(Theme.Color.warning)
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, Theme.Metric.rowVerticalPadding)
            .accessibilityElement(children: .combine)
            hairline
        }
    }

    private var saveToRow: some View {
        NavigationLink {
            SaveDestinationPicker(selection: $saveDirectory)
        } label: {
            field("Save to") {
                HStack {
                    Text(Self.displayPath(saveDirectory))
                        .font(.system(size: rowSize))
                        .foregroundStyle(Theme.Color.label1)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Color.label3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose a folder inside Goel°")
    }

    private var wifiRow: some View {
        toggleField("Wi\u{2011}Fi only", isOn: $wifiOnly)
            .accessibilityHint("Applies to every download. Turning this off lets transfers use cellular data.")
    }

    private var startPausedRow: some View {
        toggleField("Start paused", isOn: $startPaused, isLast: true)
            .accessibilityHint("Adds the download to the queue without starting it.")
    }

    // MARK: - Primary action

    private var primaryButton: some View {
        VStack(spacing: 0) {
            hairline
            Button { add() } label: {
                Text("Add Download")
                    .font(.system(size: buttonSize, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metric.minHitTarget)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: Theme.Metric.cardRadius))
            .tint(Theme.Color.ember)
            .disabled(!canAdd)
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.rowVerticalPadding)
        }
        .background(Theme.Color.elev1)
    }

    // MARK: - Row scaffolding
    //
    // `.field { padding: 12px 16px; border-bottom: .5px solid var(--ios-sep) }` from `visual.html`,
    // with a 44 pt floor and no fixed height so Dynamic Type can grow the row.

    @ViewBuilder
    private func field<Value: View>(
        _ key: String,
        isLast: Bool = false,
        @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(key)
                    .font(.system(size: rowSize))
                    .foregroundStyle(Theme.Color.label2)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                value()
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.rowVerticalPadding)
            .frame(minHeight: Theme.Metric.minHitTarget)
            .contentShape(Rectangle())

            if !isLast { hairline }
        }
    }

    /// A native 51 × 31 switch — never restyled, and green rather than the app tint, which is
    /// what both the mockup and every other iOS switch do.
    private func toggleField(_ key: String, isOn: Binding<Bool>, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            Toggle(isOn: isOn) {
                Text(key)
                    .font(.system(size: rowSize))
                    .foregroundStyle(Theme.Color.label2)
            }
            .tint(Theme.Color.success)
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, Theme.Metric.rowVerticalPadding)
            .frame(minHeight: Theme.Metric.minHitTarget)

            if !isLast { hairline }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.Color.separator)
            .frame(height: Theme.Metric.hairline)
    }

    // MARK: - Derived

    private var validation: LinkValidation { LinkValidation.check(link) }

    private var canAdd: Bool { validation.isUsable }

    private var probeState: MetadataProbe.State { probe?.state ?? .idle }

    private var isProbing: Bool { probeState.isProbing }

    private var probeResult: ProbeResult? { probeState.result }

    private var probeFilename: String? { probeResult?.filename }

    private var sizeIsKnown: Bool { probeResult?.totalBytes != nil }

    /// `Unknown`, not an em dash: the sheet is making a statement about the server, not showing
    /// a missing value.
    private var sizeText: String {
        guard let bytes = probeResult?.totalBytes else { return "Unknown" }
        return Fmt.bytes(bytes)
    }

    private var typeIsKnown: Bool { probeResult != nil }

    /// `ProbeResult.typeDescription` already produces `Disk Image · resumable` and
    /// `Video · streamable`. The one thing it cannot say is the negative, so this adds it.
    private var typeText: String {
        guard let result = probeResult else { return "Unknown" }
        if !result.isStreamable, !result.supportsResume {
            return result.typeDescription + " · not resumable"
        }
        return result.typeDescription
    }

    private var showsResumeNotice: Bool {
        guard let result = probeResult else { return false }
        return !result.supportsResume && !result.isStreamable
    }

    // MARK: - Behaviour

    private func prepare() {
        if probe == nil { probe = MetadataProbe(engine: app.engine) }

        // "Wi-Fi only" is the phone-facing name for the engine's cellular policy, which is a
        // single global rule — `Download` has no per-transfer cellular field to write to.
        wifiOnly = !app.tuning.allowCellular

        if link.isEmpty, let handed = app.pendingAddLink {
            app.pendingAddLink = nil
            link = handed
            linkChanged(link)
            return
        }

        guard link.isEmpty, let pasted = Self.pasteboardLink() else { return }
        // Prefill only. Never auto-add: silently queueing whatever someone copied is hostile.
        link = pasted.absoluteString
        linkChanged(link)
    }

    private func linkChanged(_ new: String) {
        probe?.update(for: new)

        guard !nameWasEdited else { return }
        // A provisional name from the URL, so the row is never blank while the probe runs. The
        // server's `Content-Disposition` filename replaces it if one arrives.
        let provisional = LinkValidation.check(new).url.map(Self.filename(from:)) ?? ""
        guard provisional != name else { return }
        isSettingNameProgrammatically = true
        name = provisional
    }

    private func add() {
        guard let url = validation.url else { return }
        let result = probeResult

        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = typed.isEmpty ? (result?.filename ?? Self.filename(from: url)) : typed

        // The toggle has to write somewhere real, and this is where the engine reads it.
        app.tuning.allowCellular = !wifiOnly

        let download = Download(
            url: url,
            filename: filename,
            saveDirectory: saveDirectory,
            kind: .infer(from: url),
            status: startPaused ? .paused : .queued,
            totalBytes: result?.totalBytes,
            // T10 writes a streamable file in order so it can be played while it downloads.
            isSequential: result?.isStreamable ?? false,
            supportsResume: result?.supportsResume ?? false,
            validator: result?.validator
        )

        if startPaused {
            // Queued, visible, and deliberately not handed to the engine.
            app.store.add(download)
        } else {
            app.start(download)
        }

        probe?.cancel()
        dismiss()
    }

    private func cancelAndDismiss() {
        probe?.cancel()
        dismiss()
    }

    // MARK: - Helpers

    /// `Goel°/Linux` → `Goel° › Linux`, matching the mockup's Save-to row.
    static func displayPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.isEmpty ? rootFolder : parts.joined(separator: " › ")
    }

    static func filename(from url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? fallbackFilename
    }

    /// `hasURLs` is a detection API and costs nothing; only the read that follows shows the
    /// system's "pasted from" banner, and only when there really is a link to offer.
    @MainActor
    static func pasteboardLink() -> URL? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasURLs, let url = pasteboard.url else { return nil }
        return LinkValidation.check(url.absoluteString).url
    }
}

// MARK: - SaveDestinationPicker

/// A real folder picker over the app's own container — one level of folders under `Goel°`, plus
/// the means to make another. Nothing outside the container is reachable, which is why this is a
/// list rather than a `fileImporter`.
struct SaveDestinationPicker: View {

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [String] = []
    @State private var isNaming = false
    @State private var newFolderName = ""
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                ForEach(folders, id: \.self) { path in
                    Button {
                        selection = path
                        dismiss()
                    } label: {
                        HStack {
                            Label(AddSheet.displayPath(path), systemImage: "folder")
                                .foregroundStyle(Theme.Color.label1)
                            Spacer(minLength: 0)
                            if path == selection {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.Color.ember)
                            }
                        }
                        .frame(minHeight: Theme.Metric.minHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(path == selection ? [.isButton, .isSelected] : .isButton)
                }
            } footer: {
                Text("Folders live inside Goel° in this iPhone's Documents, which the Files app shows under On My iPhone.")
            }

            Section {
                Button {
                    newFolderName = ""
                    isNaming = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .frame(minHeight: Theme.Metric.minHitTarget)
                }
            }

            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Theme.Color.danger)
                }
            }
        }
        .navigationTitle("Save to")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .alert("New Folder", isPresented: $isNaming) {
            TextField("Name", text: $newFolderName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        } message: {
            Text("The folder is created inside Goel°.")
        }
    }

    // MARK: - Container

    private static var root: URL {
        URL.documentsDirectory.appending(path: AddSheet.rootFolder, directoryHint: .isDirectory)
    }

    /// Off the main actor: this is the same `Goel°` root every non-foldered download lands in, so
    /// with many files a synchronous `contentsOfDirectory` + per-child `resourceValues` walk drops
    /// frames the moment the picker opens — the same reason `FolderEntry.listing` is detached.
    private func reload() async {
        let root = Self.root
        let rootFolder = AddSheet.rootFolder
        let found = await Task.detached(priority: .userInitiated) { () -> [String] in
            let manager = FileManager.default
            // A first launch has no container yet; making it here is what lets the Files app show it.
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)

            var found = [rootFolder]
            if let children = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                let names = children
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .map(\.lastPathComponent)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                found.append(contentsOf: names.map { "\(rootFolder)/\($0)" })
            }
            return found
        }.value
        folders = found
    }

    private func createFolder() {
        let name = newFolderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }

        let url = Self.root.appending(path: name, directoryHint: .isDirectory)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }.value
                failure = nil
                await reload()
                selection = "\(AddSheet.rootFolder)/\(name)"
            } catch {
                failure = "That folder could not be created: \(error.localizedDescription)"
            }
        }
    }
}
