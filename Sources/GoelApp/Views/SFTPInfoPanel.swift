import SwiftUI
import GoelCore

struct SFTPEntryInfo: Equatable {
    let name: String
    let path: String
    let attributes: SFTPAttributes
    let linkTarget: String?
}

struct SFTPInfoPanel: View {

    let entry: SFTPEntry
    let info: SFTPEntryInfo?
    let folderSize: Int64?
    let isSizing: Bool
    /// Why the folder walk produced no size — a blank "—" hides real failures.
    var sizeError: String? = nil
    let onApplyPermissions: (UInt32) -> Void
    let onClose: () -> Void

    @State private var mode: UInt32 = 0
    @State private var octalText = ""
    /// Set once the fetched mode is adopted, so re-renders mid-edit don't snap the checkboxes back to the server's value.
    @State private var adoptedMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        facts(info)
                        Divider()
                        permissions(info)
                    }
                    .padding(16)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.t("Loading information"))
            }
        }
        .frame(width: 340, height: 460)
        .background(.regularMaterial)
        .onChange(of: info) { _, new in adopt(new) }
        .onAppear { adopt(info) }
    }

    private func adopt(_ info: SFTPEntryInfo?) {
        guard !adoptedMode, let info else { return }
        adoptedMode = true
        mode = info.attributes.mode
        octalText = info.attributes.octalString
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(kindLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("Close info"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var iconName: String {
        if entry.isSymlink { return "arrow.up.forward.square" }
        return entry.isDirectory ? "folder" : "doc"
    }

    private var kindLabel: String {
        if entry.isSymlink { return entry.isDirectory ? L10n.t("Alias to folder") : L10n.t("Alias") }
        return entry.isDirectory ? L10n.t("Folder") : L10n.t("File")
    }

    @ViewBuilder
    private func facts(_ info: SFTPEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row(L10n.t("Where"), SFTPBrowserPaths.parent(of: info.path))
            row(L10n.t("Size"), sizeText(info))
            if let modified = info.attributes.modified {
                row(L10n.t("Modified"), modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let target = info.linkTarget, !target.isEmpty {
                row(L10n.t("Points to"), target)
            }
            row(L10n.t("Owner"), L10n.t("uid %1$@ · gid %2$@",
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

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("%1$@: %2$@", label, value))
    }

    @ViewBuilder
    private func permissions(_ info: SFTPEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("Permissions")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(SFTPPermissions.string(for: mode))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 50)
                    Text(L10n.t("Read")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(L10n.t("Write")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(L10n.t("Execute")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                permissionRow("Owner", read: 0o400, write: 0o200, execute: 0o100)
                permissionRow("Group", read: 0o040, write: 0o020, execute: 0o010)
                permissionRow("Everyone", read: 0o004, write: 0o002, execute: 0o001)
            }

            HStack(spacing: 8) {
                Text(L10n.t("Octal")).font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("0644", text: $octalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 68)
                    .onSubmit(applyOctal)
                    .accessibilityLabel(L10n.t("Permissions in octal"))
                Spacer()
                Button(L10n.t("Apply")) { onApplyPermissions(mode) }
                    .disabled(mode == info.attributes.mode)
            }
            // Typed octal is adopted only on submit, so a half-typed "6" can't briefly strip every permission bit off the checkboxes.
            if SFTPPermissions.parse(octal: octalText) == nil && !octalText.isEmpty {
                Text(L10n.t("Enter three or four digits, 0–7."))
                    .font(.system(size: 10)).foregroundStyle(Theme.red)
            }
        }
    }

    private func applyOctal() {
        guard let parsed = SFTPPermissions.parse(octal: octalText) else { return }
        mode = parsed
    }

    private func permissionRow(_ label: String, read: UInt32, write: UInt32, execute: UInt32) -> some View {
        GridRow {
            Text(L10n.t(label)).font(.system(size: 11)).frame(width: 50, alignment: .leading)
            permissionBox(label, "read", read)
            permissionBox(label, "write", write)
            permissionBox(label, "execute", execute)
        }
    }

    private func permissionBox(_ who: String, _ what: String, _ bit: UInt32) -> some View {
        Toggle("", isOn: Binding(
            get: { mode & bit != 0 },
            set: { on in
                mode = SFTPPermissions.setting(mode, bit: bit, on: on)
                octalText = String(format: "%04o", mode)
            }))
        .labelsHidden()
        .accessibilityLabel(L10n.t("%1$@ can %2$@", L10n.t(who), L10n.t(what)))
    }
}
