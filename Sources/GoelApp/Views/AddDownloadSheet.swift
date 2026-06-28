import SwiftUI
import AppKit
import GoelCore

/// The Add-download sheet: a URL / magnet field (batch lines supported), a
/// destination chooser, and a task priority — wired straight into the manager.
struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var destination: String = ""
    @State private var priority: FilePriority = .normal

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "link")
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                Text("Add download").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(18)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL or magnet link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    Text("Paste several lines to add them all at once. Magnet links resolve metadata from peers before the size is known.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Save to").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        HStack {
                            Text(destination.isEmpty ? vm.settings.defaultSaveDirectory : destination)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseFolder() }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("", selection: $priority) {
                            Text("High").tag(FilePriority.high)
                            Text("Normal").tag(FilePriority.normal)
                            Text("Low").tag(FilePriority.low)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to queue") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 560)
    }

    private func add() {
        let dir = destination.isEmpty ? nil : destination
        vm.add(rawLines: text, saveDirectory: dir, priority: priority)
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }
}
