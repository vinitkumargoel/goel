import SwiftUI
import GoelCore

/// Step 2 for one link: the name, what's already known about it, and where and when it starts.
struct AddConfirmStep: View {
    @ObservedObject var model: AddSheetModel
    let preview: DownloadPreview

    /// Leaves room for the sheet's header and footer, the window title and the menu bar.
    private var bodyMaxHeight: CGFloat {
        CappedScrollView<EmptyView>.screenCap(reserving: 240, upTo: 600)
    }

    private var unreachable: String? { model.unreachableMessage(preview) }

    var body: some View {
        VStack(spacing: 0) {
            header
            CappedScrollView(maxHeight: bodyMaxHeight) {
                content
            }
            .task(id: model.diskSpaceFolder(for: preview)) {
                await model.refreshFreeSpace(in: model.diskSpaceFolder(for: preview))
            }
            .onAppear { model.confirmAppeared() }
            footer
        }
    }

    // MARK: Header

    private var artKind: StudioArtKind {
        preview.kind == .torrent && preview.files.count > 1
            ? .folder
            : StudioArtKind(FileType.classify(fileName: preview.suggestedName, isTorrent: preview.kind == .torrent))
    }

    private var eyebrow: String {
        [L10n.t("Step 2 of 2"), preview.kind.badgeLabel, model.previewHost(preview)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var header: some View {
        AddFlowHeader(title: L10n.t("Review & start"), eyebrow: eyebrow) {
            StudioFileArtwork(kind: artKind, size: .m)
        } trailing: {
            EmptyView()
        }
    }

    // MARK: Body

    private var content: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            AddNameSection(preview: preview, sizeText: model.sizeText(preview),
                           baseName: preview.kind == .torrent ? nil : model.nameBinding(preview))
            notes
            if !preview.files.isEmpty {
                AddFileTreeList(files: preview.files, selectable: preview.kind == .torrent,
                                deselectedFileIDs: $model.deselectedFileIDs)
            }
            if model.allFilesDeselected(preview) {
                StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill",
                           message: L10n.t("Pick at least one file to download."))
            }
            failureOrNote
            if model.offersMedia(preview) {
                AddMediaSection(model: model, preview: preview)
            }
            options
            AddDiskSpaceRow(model: model, preview: preview)
            if model.showsAdvanced(preview) {
                AddAdvancedOptions(model: model, preview: preview)
            }
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, Studio.Space.xxs)
        .padding(.bottom, Studio.Space.xl)
    }

    @ViewBuilder private var notes: some View {
        if let warning = model.existingFileWarning(preview) {
            StudioNote(tone: .warn, symbol: "doc.on.doc", message: warning)
        }
        if let duplicate = model.duplicateMessage(preview) {
            StudioNote(tone: .warn, symbol: "exclamationmark.triangle.fill", message: duplicate)
        }
    }

    @ViewBuilder private var failureOrNote: some View {
        if let failure = unreachable {
            AddCallout(tone: .warn, symbol: "exclamationmark.triangle.fill", message: failure,
                       accessibilityLabel: L10n.t("Error. %@", failure)) {
                Button(L10n.t("Try again")) { model.retryResolve() }
                    .buttonStyle(.studio(.secondary, size: .small))
                Button(L10n.t("Continue anyway")) { model.start(preview) }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .disabled(model.isResolvingMedia || model.allFilesDeselected(preview))
                    .help(L10n.t("Continue anyway adds it straight to the queue — the name and size fill in as it starts."))
            }
        } else if let note = preview.note {
            StudioNote(tone: .info, symbol: "info.circle.fill", message: note)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            HStack(alignment: .top, spacing: Studio.Space.ml) {
                AddOptionColumn(title: L10n.t("Save to")) {
                    Dropdown(selection: $model.saveSelection, items: model.saveOptions,
                             accessibilityName: L10n.t("Save to")) { newValue in
                        model.handleSaveSelection(newValue)
                    }
                    if model.saveSelection == AddSheetModel.SaveOption.automatic {
                        let folder = model.diskSpaceFolder(for: preview)
                        Text(L10n.t("→ %@", (folder as NSString).abbreviatingWithTildeInPath))
                            .studioFont(.caption)
                            .foregroundStyle(Studio.Palette.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel(L10n.t("Saves to %@", folder))
                    }
                }
                AddOptionColumn(title: L10n.t("Priority")) { PriorityPicker(priority: $model.priority) }
            }
            HStack(alignment: .top, spacing: Studio.Space.ml) {
                AddOptionColumn(title: L10n.t("Start")) { StartPicker(selection: $model.startSelection) }
                AddOptionColumn(title: L10n.t("When done")) {
                    WhenDonePicker(whenDone: $model.whenDone, width: nil)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        AddFlowFooter {
            Button(L10n.t("Back"), systemImage: "chevron.left") { model.goBack() }
                .buttonStyle(.studio(.ghost))
            Spacer()
            Button(L10n.t("Cancel")) { model.finish() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.studio(.secondary))
            Button(unreachable == nil ? L10n.t("Start download") : L10n.t("Continue anyway"),
                   systemImage: "arrow.down") {
                model.start(preview)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.studio(.primary))
            // A second press during a resolve queues a second copy; an all-unticked torrent fetches nothing.
            .disabled(model.isResolvingMedia || model.allFilesDeselected(preview))
        }
    }
}
