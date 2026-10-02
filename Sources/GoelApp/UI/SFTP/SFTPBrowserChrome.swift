import SwiftUI
import AppKit
import GoelCore

/// The browser's banners, info side sheet, transfers dock and footer.
extension SFTPBrowserView {

    // MARK: - Banners

    @ViewBuilder
    var banners: some View {
        if model.error != nil || model.deleteProgress != nil {
            VStack(spacing: Studio.Space.s) {
                if let error = model.error { errorBanner(error) }
                if let note = model.deleteProgress { deleteProgressBanner(note) }
            }
            .padding(.horizontal, Studio.Space.gutter)
            .padding(.top, Studio.Space.m)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        let isLong = message.count > 140 || message.contains("\n")
        return HStack(alignment: .firstTextBaseline, spacing: Studio.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(StudioFonts.font(.ui, size: 13, weight: 650))
                .foregroundStyle(Studio.Palette.bad)
                .a11yDecorative()
            Text(message)
                .studioFont(.callout.weight(450))
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(errorExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: errorExpanded)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.t("Error. %@", message))
            if isLong {
                Button(errorExpanded ? L10n.t("Hide Details") : L10n.t("Show Details")) {
                    errorExpanded.toggle()
                }
                .buttonStyle(.studio(.ghost, size: .small))
            }
            Button(L10n.t("Copy")) { copyToPasteboard(message) }
                .buttonStyle(.studio(.ghost, size: .small))
                .accessibilityLabel(L10n.t("Copy error message"))
            StudioIconButton("xmark", label: L10n.t("Dismiss error"), size: .small) { model.error = nil }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.leading, Studio.Space.m)
        .padding(.trailing, Studio.Space.xs)
        .padding(.vertical, Studio.Space.xs)
        .background(Studio.Palette.badSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        .onAppear { A11yAnnouncer.announce(L10n.t("Error. %@", message)) }
    }

    private func deleteProgressBanner(_ note: String) -> some View {
        HStack(spacing: Studio.Space.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(Studio.Palette.accent)
            Text(note)
                .studioFont(.callout.weight(450).tabular)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Studio.Space.s)
            Button(L10n.t("Cancel")) { model.cancelDelete() }
                .buttonStyle(.studio(.ghost, size: .small))
                .a11yButton(L10n.t("Cancel delete"))
        }
        .padding(.leading, Studio.Space.m)
        .padding(.trailing, Studio.Space.xs)
        .padding(.vertical, Studio.Space.xs)
        .background(Studio.Palette.accentSoft,
                    in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
    }

    // MARK: - Info sheet

    func infoPanel(_ entry: SFTPEntry) -> some View {
        SFTPInfoPanel(entry: entry, info: info.info,
                      folderSize: info.folderSize,
                      isSizing: info.isSizing,
                      sizeError: info.sizeError,
                      onApplyPermissions: { mode in applyPermissions(entry, mode) },
                      onClose: { closeInfo() },
                      onDownload: { downloadTargets([entry]) },
                      onPreview: { primaryAction(entry) })
            .id(entry.id)
            .padding(.top, Studio.Space.ml)
            .padding(.trailing, Studio.Space.ml)
            .padding(.bottom, Studio.Space.ml)
    }

    // MARK: - Transfers dock

    @ViewBuilder
    var transferFooter: some View {
        let transfers = myTransfers
        if !transfers.isEmpty {
            SFTPTransferPanel(transfers: transfers, connection: model.connection, volumeSpace: volumeSpace,
                              historyOverride: transferHistory)
                .padding(.top, Studio.Space.s)
        }
    }

    // MARK: - Footer

    var statusFooter: some View {
        let entries = visibleEntries
        let selected = selectedEntries
        return HStack(spacing: Studio.Space.sm) {
            Text(SFTPBrowserListing.itemSummary(entries))
            if let space = volumeSpace, space.totalBytes > 0 {
                Text(verbatim: "·").foregroundStyle(Studio.Palette.ink3)
                Text(L10n.t("%@ free", space.freeBytes.byteString))
                    .help(L10n.t("%1$@ of %2$@ used on this volume",
                                 space.usedBytes.byteString, space.totalBytes.byteString))
            }
            Spacer(minLength: Studio.Space.s)
            if !selection.isEmpty {
                let bytes = SFTPBrowserListing.fileBytes(selected)
                Text(bytes > 0 ? L10n.t("%1$@ · %2$@", L10n.t("%d selected", selection.count), bytes.byteString)
                               : L10n.t("%d selected", selection.count))
                    .foregroundStyle(Studio.Palette.accent)
                Button(L10n.t("Clear")) { selection.removeAll() }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .accessibilityLabel(L10n.t("Deselect All"))
            } else {
                let total = SFTPBrowserListing.fileBytes(entries)
                if total > 0 {
                    Text(total.byteString).studioFont(.mono)
                }
            }
        }
        .studioFont(.small.tabular)
        .foregroundStyle(Studio.Palette.ink2)
        .padding(.horizontal, Studio.Space.l)
        .frame(height: 34)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Name sheet

/// New Folder or Rename: which, and the name the field starts with.
struct SFTPNameRequest: Identifiable {
    enum Kind {
        case newFolder
        case rename(SFTPEntry)
    }

    let id = UUID()
    let kind: Kind
    let initialName: String
}

/// A small Studio sheet with one name field. Return creates/renames; the button stays off for a
/// blank name, as Finder's does.
struct SFTPNameSheet: View {
    let request: SFTPNameRequest
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var text: String

    init(request: SFTPNameRequest, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCancel = onCancel
        self.onCommit = onCommit
        _text = State(initialValue: request.initialName)
    }

    private var isRename: Bool {
        if case .rename = request.kind { return true }
        return false
    }

    private var title: String {
        switch request.kind {
        case .newFolder: return L10n.t("New Folder")
        case .rename(let entry): return L10n.t("Rename “%@”", entry.name)
        }
    }

    private var canCommit: Bool { RemoteNameInput.isAcceptable(text) }

    var body: some View {
        StudioSheet(title: title, symbol: isRename ? "pencil" : "folder.badge.plus", width: 400) {
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                Text(L10n.t("Name"))
                    .studioFont(.callout.weight(650))
                    .foregroundStyle(Studio.Palette.ink2)
                TextField(L10n.t("Name"), text: $text)
                    .textFieldStyle(.studio)
                    .autocorrectionDisabled()
                    .onSubmit { if canCommit { onCommit(text) } }
            }
        } footer: {
            StudioSheetFooter(onCancel: onCancel,
                              primaryTitle: isRename ? L10n.t("Rename") : L10n.t("Create"),
                              primaryEnabled: canCommit,
                              onPrimary: { onCommit(text) })
        }
    }
}
