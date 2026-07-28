import SwiftUI
import GoelCore

/// One remote item's full metadata, as fetched for the info panel.
struct SFTPEntryInfo: Equatable {
    let name: String
    let path: String
    let attributes: SFTPAttributes
    /// Where a symlink points, or nil for a non-link (and for a link whose
    /// target the server wouldn't tell us).
    let linkTarget: String?
}

/// Goel's answer to Finder's ⌘I: everything the server knows about one item, including what a
/// listing can't show — a symlink's target, owner and group, and a folder's real recursive size.
struct SFTPInfoPanel: View {

    let entry: SFTPEntry
    let info: SFTPEntryInfo?
    /// The recursive byte count for a folder, once it has been walked.
    let folderSize: Int64?
    let isSizing: Bool
    let onApplyPermissions: (UInt32) -> Void
    let onClose: () -> Void

    @State private var mode: UInt32 = 0
    @State private var octalText = ""
    /// Set once the fetched mode has been adopted, so re-renders while the user
    /// is mid-edit don't snap the checkboxes back to the server's value.
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
                    .accessibilityLabel("Loading information")
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
                .accessibilityLabel("Close info")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var iconName: String {
        if entry.isSymlink { return "arrow.up.forward.square" }
        return entry.isDirectory ? "folder" : "doc"
    }

    private var kindLabel: String {
        // A link is described by what it is *and* what it resolves to: "Alias to folder" tells you it
        // opens like a folder and that deleting it deletes only the link.
        if entry.isSymlink { return entry.isDirectory ? "Alias to folder" : "Alias" }
        return entry.isDirectory ? "Folder" : "File"
    }

    @ViewBuilder
    private func facts(_ info: SFTPEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Where", SFTPBrowserPaths.parent(of: info.path))
            row("Size", sizeText(info))
            if let modified = info.attributes.modified {
                row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let target = info.linkTarget, !target.isEmpty {
                row("Points to", target)
            }
            row("Owner", "uid \(info.attributes.ownerID) · gid \(info.attributes.groupID)")
        }
    }

    /// A directory's listed size is its inode's, not its contents' — showing it would mislead, so
    /// folders show the walked total and say so while the walk runs.
    private func sizeText(_ info: SFTPEntryInfo) -> String {
        guard info.attributes.isDirectory else { return info.attributes.size.byteString }
        if let folderSize { return folderSize.byteString }
        return isSizing ? "Calculating…" : "—"
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
        .accessibilityLabel("\(label): \(value)")
    }

    @ViewBuilder
    private func permissions(_ info: SFTPEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Permissions").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(SFTPPermissions.string(for: mode))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 50)
                    Text("Read").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Write").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Execute").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                permissionRow("Owner", read: 0o400, write: 0o200, execute: 0o100)
                permissionRow("Group", read: 0o040, write: 0o020, execute: 0o010)
                permissionRow("Everyone", read: 0o004, write: 0o002, execute: 0o001)
            }

            HStack(spacing: 8) {
                Text("Octal").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("0644", text: $octalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 68)
                    .onSubmit(applyOctal)
                    .accessibilityLabel("Permissions in octal")
                Spacer()
                Button("Apply") { onApplyPermissions(mode) }
                    .disabled(mode == info.attributes.mode)
            }
            // Typed octal is only adopted on submit, so a half-typed "6" can't
            // briefly strip every permission bit off the checkboxes.
            if SFTPPermissions.parse(octal: octalText) == nil && !octalText.isEmpty {
                Text("Enter three or four digits, 0–7.")
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
            Text(label).font(.system(size: 11)).frame(width: 50, alignment: .leading)
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
        .accessibilityLabel("\(who) can \(what)")
    }
}
