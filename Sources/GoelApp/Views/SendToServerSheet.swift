import SwiftUI
import GoelCore

/// Picks a saved SFTP server and folder for a finished download, then hands it to the upload queue.
struct SendToServerSheet: View {
    let task: DownloadTask

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var serverID: SFTPConnection.ID?
    @State private var directory: String = "."
    @State private var removeLocal: Bool = false

    private var chosen: SFTPConnection? { vm.destinationServers.first { $0.id == serverID } }
    private var folderError: String? { vm.destinationFolderError(directory) }
    private var canSend: Bool { chosen != nil && folderError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to server")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fileSummary
                    serverPicker
                    folderField
                    Toggle("Remove the local copy once it lands", isOn: $removeLocal)
                        .font(.system(size: 12))
                    if removeLocal {
                        Text("The local file is deleted only after the server confirms the full size.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !vm.unpinnedServers.isEmpty { unpinnedNotice }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
        .onAppear(perform: seed)
    }

    // MARK: Sections

    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text((task.totalBytes ?? task.bytesDownloaded).byteString)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var serverPicker: some View {
        labeled("Server") {
            Picker("", selection: $serverID) {
                ForEach(vm.destinationServers) { server in
                    Text(server.label).tag(Optional(server.id))
                }
            }
            .labelsHidden()
            .onChange(of: serverID) { _, _ in
                if let chosen { directory = chosen.resolvedUploadPath }
            }
        }
    }

    private var folderField: some View {
        labeled("Folder on the server") {
            VStack(alignment: .leading, spacing: 4) {
                TextField(".", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if let folderError {
                    Text(folderError).font(.system(size: 10)).foregroundStyle(Theme.red)
                } else {
                    Text("“.” means the folder you land in when you sign in.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Servers whose identity has never been confirmed are not offered — say so rather than silently omitting them.
    private var unpinnedNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Not listed yet").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(vm.unpinnedServers.map(\.label).joined(separator: ", ")) — browse each one once so Goel can check its identity first.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Actions

    /// Prefill from the download's existing destination if it has one, else from the first offered server.
    private func seed() {
        if let existing = task.remoteDestination,
           vm.destinationServers.contains(where: { $0.id == existing.connectionID }) {
            serverID = existing.connectionID
            directory = existing.directory
            removeLocal = existing.removeLocalAfterUpload
            return
        }
        serverID = vm.destinationServers.first?.id
        directory = chosen?.resolvedUploadPath ?? "."
    }

    private func send() {
        guard let chosen, folderError == nil else { return }
        vm.sendToServer(task, destination: vm.makeDestination(for: chosen,
                                                              directory: directory,
                                                              removeLocalAfterUpload: removeLocal))
        dismiss()
    }
}
