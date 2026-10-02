import SwiftUI
import GoelCore

/// Get Info for one remote item, as a side sheet beside the files: where it is, its size (a
/// folder's walked total), when it changed, what a link points to, who owns it, and a
/// permissions grid with an octal field and Apply.
struct SFTPInfoPanel: View {

    let entry: SFTPEntry
    let info: SFTPEntryInfo?
    let folderSize: Int64?
    let isSizing: Bool
    /// Why the folder walk produced no size — a blank "—" hides real failures.
    var sizeError: String? = nil
    let onApplyPermissions: (UInt32) -> Void
    let onClose: () -> Void
    var onDownload: (() -> Void)? = nil
    /// Quick Look for a file, Open for a folder.
    var onPreview: (() -> Void)? = nil

    @State private var mode: UInt32 = 0
    @State private var octalText = ""
    /// Set once the fetched mode is adopted, so re-renders mid-edit don't snap the checkboxes back to the server's value.
    @State private var adoptedMode = false

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: Studio.Space.l) {
                        facts(info)
                        StudioDivider()
                        permissions(info)
                    }
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.bottom, Studio.Space.l)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Studio.Palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.t("Loading information"))
            }
            Spacer(minLength: 0)
            actionBar
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
        .onChange(of: info) { _, new in adopt(new) }
        .onAppear { adopt(info) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Info for %@", entry.name))
    }

    private func adopt(_ info: SFTPEntryInfo?) {
        guard !adoptedMode, let info else { return }
        adoptedMode = true
        mode = info.attributes.mode
        octalText = info.attributes.octalString
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Studio.Space.m) {
            SFTPEntryArtwork(entry: entry, size: .l)
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                FileNameText(entry.name, lineLimit: 3)
                    .studioFont(.headline)
                    .foregroundStyle(Studio.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(SFTPFileIcon.kindLabel(for: entry))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StudioIconButton("xmark", label: L10n.t("Close info"), size: .small, action: onClose)
        }
        .padding(.horizontal, Studio.Space.l)
        .padding(.top, Studio.Space.l)
        .padding(.bottom, Studio.Space.m)
    }

    // MARK: - Facts

    private func facts(_ info: SFTPEntryInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Studio.Space.l, verticalSpacing: 9) {
            factRow(L10n.t("Where"), SFTPBrowserPaths.parent(of: info.path), mono: true)
            factRow(L10n.t("Size"), sizeText(info))
            if let modified = info.attributes.modified {
                factRow(L10n.t("Modified"), modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let target = info.linkTarget, !target.isEmpty {
                factRow(L10n.t("Points to"), target, mono: true)
            }
            factRow(L10n.t("Owner"), L10n.t("uid %1$@ · gid %2$@",
                                          String(info.attributes.ownerID), String(info.attributes.groupID)))
        }
    }

    /// A directory's listed size is its inode's, not its contents', so folders show the walked total instead.
    private func sizeText(_ info: SFTPEntryInfo) -> String {
        guard info.attributes.isDirectory else { return info.attributes.size.byteString }
        if let folderSize { return folderSize.byteString }
        if isSizing { return L10n.t("Calculating…") }
        return sizeError ?? "—"
    }

    private func factRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .studioFont(.callout.weight(400))
                .foregroundStyle(Studio.Palette.ink3)
            Text(value)
                .studioFont(mono ? .mono : .callout.weight(550))
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("%1$@: %2$@", label, value))
    }

    // MARK: - Permissions

    private func permissions(_ info: SFTPEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            HStack {
                Text(L10n.t("Permissions"))
                    .studioFont(.eyebrow)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(SFTPPermissions.string(for: mode))
                    .studioFont(.mono)
                    .foregroundStyle(Studio.Palette.ink2)
            }
            Grid(alignment: .center, horizontalSpacing: Studio.Space.s, verticalSpacing: Studio.Space.xs) {
                GridRow {
                    Color.clear.frame(width: 70, height: 1)
                    columnTitle(L10n.t("Read"))
                    columnTitle(L10n.t("Write"))
                    columnTitle(L10n.t("Execute"))
                }
                permissionRow(L10n.t("Owner"), read: 0o400, write: 0o200, execute: 0o100)
                permissionRow(L10n.t("Group"), read: 0o040, write: 0o020, execute: 0o010)
                permissionRow(L10n.t("Everyone"), read: 0o004, write: 0o002, execute: 0o001)
            }
            octalRow(info)
            // Typed octal is adopted only on submit, so a half-typed "6" can't briefly strip every permission bit off the checkboxes.
            if SFTPPermissions.parse(octal: octalText) == nil && !octalText.isEmpty {
                Text(L10n.t("Enter three or four digits, 0–7."))
                    .studioFont(.caption)
                    .foregroundStyle(Studio.Palette.bad)
            }
        }
    }

    private func octalRow(_ info: SFTPEntryInfo) -> some View {
        HStack(spacing: Studio.Space.s) {
            Text(L10n.t("Octal"))
                .studioFont(.callout.weight(650))
                .foregroundStyle(Studio.Palette.ink2)
            TextField("0644", text: $octalText)
                .textFieldStyle(.studio(size: .small))
                .studioFont(.monoBody)
                .frame(width: 84)
                .onSubmit(applyOctal)
                .accessibilityLabel(L10n.t("Permissions in octal"))
            Spacer()
            Button(L10n.t("Apply")) {
                applyOctal()
                onApplyPermissions(mode)
            }
            .buttonStyle(.studio(.secondary, size: .small))
            .disabled(pendingMode == info.attributes.mode)
        }
        .padding(.top, Studio.Space.xxs)
    }

    /// What Apply would send: a valid typed octal counts even before Return adopts it.
    private var pendingMode: UInt32 { SFTPPermissions.parse(octal: octalText) ?? mode }

    private func applyOctal() {
        guard let parsed = SFTPPermissions.parse(octal: octalText) else { return }
        mode = parsed
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title)
            .studioFont(.tiny.weight(600))
            .foregroundStyle(Studio.Palette.ink3)
            .frame(maxWidth: .infinity)
    }

    private func permissionRow(_ who: String, read: UInt32, write: UInt32, execute: UInt32) -> some View {
        GridRow {
            Text(who)
                .studioFont(.small.weight(650))
                .foregroundStyle(Studio.Palette.ink)
                .frame(width: 70, alignment: .leading)
            permissionBox(who, L10n.t("read"), read)
            permissionBox(who, L10n.t("write"), write)
            permissionBox(who, L10n.t("execute"), execute)
        }
    }

    private func permissionBox(_ who: String, _ what: String, _ bit: UInt32) -> some View {
        // An empty label: the grid's row and column titles say what the box is; VoiceOver hears it below.
        Toggle(isOn: Binding(
            get: { mode & bit != 0 },
            set: { on in
                mode = SFTPPermissions.setting(mode, bit: bit, on: on)
                octalText = String(format: "%04o", mode)
            })) { EmptyView() }
        .toggleStyle(.studioCheckbox)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.t("%1$@ can %2$@", who, what))
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionBar: some View {
        if onDownload != nil || onPreview != nil {
            HStack(spacing: Studio.Space.s) {
                if let onDownload {
                    Button(L10n.t("Download"), systemImage: "arrow.down.doc", action: onDownload)
                        .buttonStyle(.studio(.primary, fullWidth: true))
                        .accessibilityLabel(entry.isDirectory ? L10n.t("Download Folder") : L10n.t("Download"))
                }
                if let onPreview {
                    Button(entry.isDirectory ? L10n.t("Open") : L10n.t("Quick Look"),
                           systemImage: entry.isDirectory ? "folder" : "eye", action: onPreview)
                        .buttonStyle(.studio(.secondary, fullWidth: true))
                }
            }
            .padding(.horizontal, Studio.Space.l)
            .padding(.vertical, Studio.Space.m)
            .background(Studio.Palette.well)
            .overlay(alignment: .top) { StudioDivider() }
        }
    }
}
