import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The Add-download sheet: a drop zone, a URL / magnet field (batch lines
/// supported), a preset destination picker, and a task priority — all wired
/// straight into the manager.
struct AddDownloadSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var priority: FilePriority = .normal
    @State private var isDropTargeted = false
    /// Optional integrity hash; verified after the (single) download finishes.
    @State private var checksumText: String = ""

    /// The chosen "Save to" preset. Holds one of the sentinel tags below or a
    /// concrete folder path; `add()` maps `automatic` to a `nil` directory so the
    /// manager applies the configured default-folder rule.
    @State private var saveSelection: String = SaveOption.automatic
    /// The last committed selection, used to revert when the user cancels the
    /// folder-chooser panel reached via "Choose folder…".
    @State private var previousSaveSelection: String = SaveOption.automatic
    /// A folder picked through the panel, surfaced as its own picker row.
    @State private var customFolder: String?

    /// Sentinel tags for the non-path picker rows.
    private enum SaveOption {
        static let automatic = "automatic"
        static let choose = "__choose__"
    }

    private var downloadsPath: String { ("~/Downloads" as NSString).expandingTildeInPath }
    private var moviesPath: String { ("~/Movies" as NSString).expandingTildeInPath }

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
                dropZone

                VStack(alignment: .leading, spacing: 6) {
                    Text("URL, magnet, or .m3u8 stream")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    Text("Paste several lines to add them all at once. Magnet links resolve metadata from peers; .m3u8 links are grabbed as a single video.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Save to").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("", selection: $saveSelection) {
                            Text("Automatic").tag(SaveOption.automatic)
                            Text("~/Downloads").tag(downloadsPath)
                            Text("~/Movies").tag(moviesPath)
                            if let customFolder, customFolder != downloadsPath, customFolder != moviesPath {
                                Text((customFolder as NSString).abbreviatingWithTildeInPath).tag(customFolder)
                            }
                            Divider()
                            Text("Choose folder…").tag(SaveOption.choose)
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: saveSelection) { _, newValue in
                            handleSaveSelection(newValue)
                        }
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

                checksumField
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

    /// The dashed drop affordance above the URL field, mirroring the design. A
    /// dropped web URL or `.torrent` file URL is appended to the URL editor so the
    /// user can review it before committing.
    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isDropTargeted ? Theme.accent : .secondary)
            (Text("Drag a URL or ") + Text(".torrent").bold() + Text(" file here"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.hairline,
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    /// Optional checksum entry with live algorithm detection. Only verified for a
    /// single download — a checksum alongside a multi-line batch is ignored.
    private var checksumField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checksum (optional)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("MD5, SHA-1, or SHA-256 hex", text: $checksumText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
            if !checksumText.trimmingCharacters(in: .whitespaces).isEmpty {
                if let parsed = Checksum.parse(checksumText) {
                    Label("\(parsed.algorithm.displayName) — verified after the download finishes",
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.green)
                } else {
                    Label("Not a valid MD5 / SHA-1 / SHA-256 hex digest",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
    }

    private func add() {
        vm.add(rawLines: text, saveDirectory: resolvedSaveDirectory, priority: priority,
               expectedChecksum: Checksum.parse(checksumText))
        dismiss()
    }

    /// The directory to hand the manager. `automatic` (and the unreachable
    /// `choose` sentinel) map to `nil` so the configured default-folder rule wins.
    private var resolvedSaveDirectory: String? {
        switch saveSelection {
        case SaveOption.automatic, SaveOption.choose: return nil
        default: return saveSelection
        }
    }

    /// React to a "Save to" change: the `choose` sentinel opens a folder panel and
    /// either records the picked folder or reverts to the prior selection.
    private func handleSaveSelection(_ newValue: String) {
        guard newValue == SaveOption.choose else {
            previousSaveSelection = newValue
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customFolder = url.path
            saveSelection = url.path
            previousSaveSelection = url.path
        } else {
            saveSelection = previousSaveSelection
        }
    }

    /// Load every URL the drag carries and append the locators to the URL editor.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !urlProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var dropped: [String] = []
        for provider in urlProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); dropped.append(url.absoluteString); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !dropped.isEmpty else { return }
            appendLines(dropped)
        }
        return true
    }

    /// Append newline-separated locators to ``text`` without clobbering existing
    /// input, keeping each entry on its own line.
    private func appendLines(_ lines: [String]) {
        let joined = lines.joined(separator: "\n")
        if text.isEmpty {
            text = joined
        } else if text.hasSuffix("\n") {
            text += joined
        } else {
            text += "\n" + joined
        }
    }
}
