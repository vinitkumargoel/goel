import SwiftUI
import AppKit
import GoelCore

/// The download-history archive: everything that ever completed, searchable,
/// exportable as CSV, and re-downloadable — independent of whether the task
/// still sits in the queue list.
struct HistoryView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var entries: [HistoryEntry]?
    @State private var search = ""

    private var visible: [HistoryEntry] {
        guard let entries else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(q) || $0.locator.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("Done") { vm.isHistoryPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            TextField("Search name or link", text: $search)
                .textFieldStyle(.roundedBorder)

            if let entries {
                if entries.isEmpty {
                    Text("Nothing here yet — finished downloads are archived automatically.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    list
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            HStack {
                Button("Export CSV…") { exportCSV() }
                    .disabled((entries ?? []).isEmpty)
                Spacer()
                Button("Clear History", role: .destructive) {
                    vm.requestConfirm(
                        title: "Clear the download history?",
                        message: "This removes every archived entry. Files on disk are not touched.",
                        confirmTitle: "Clear History",
                        destructive: true
                    ) {
                        vm.clearHistory()
                        entries = []
                    }
                }
                .disabled((entries ?? []).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 640, height: 460)
        .task { entries = await vm.fetchHistory() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { entry in
                    row(entry)
                    if entry.id != visible.last?.id { Divider().opacity(0.4) }
                }
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(entry.kind))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened)
                     + (entry.totalBytes.map { " · \($0.byteString)" } ?? ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                iconButton("arrow.down.circle", help: "Download again") {
                    vm.redownload(entry)
                }
                iconButton("magnifyingglass.circle", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.savePath)])
                }
                .disabled(!FileManager.default.fileExists(atPath: entry.savePath))
                iconButton("doc.on.doc", help: "Copy link") {
                    vm.copyToPasteboard(entry.locator)
                }
                iconButton("trash", help: "Remove entry") {
                    vm.deleteHistoryEntry(entry.id)
                    entries?.removeAll { $0.id == entry.id }
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func iconName(_ kind: DownloadKind) -> String {
        switch kind {
        case .http: return "arrow.down.circle"
        case .torrent: return "point.3.connected.trianglepath.dotted"
        case .hls: return "play.rectangle"
        case .ftp: return "server.rack"
        case .sftp: return "lock.rectangle.on.rectangle"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "GoelDownloader-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.exportHistoryCSV(entries ?? [], to: url)
    }
}

// MARK: - Scheduled-start presets

/// Quick-pick presets for "start this download later" (context menu + add flow).
struct ScheduledStartOption: Identifiable {
    let id: String
    let label: String
    let date: () -> Date

    static var presets: [ScheduledStartOption] {
        [
            ScheduledStartOption(id: "1h", label: "In 1 Hour") {
                Date().addingTimeInterval(3600)
            },
            ScheduledStartOption(id: "4h", label: "In 4 Hours") {
                Date().addingTimeInterval(4 * 3600)
            },
            ScheduledStartOption(id: "night", label: "Tonight at 2 AM") { Self.next(hour: 2) },
            ScheduledStartOption(id: "morning", label: "Tomorrow at 8 AM") { Self.next(hour: 8) },
        ]
    }

    /// The next occurrence of `hour`:00 strictly in the future.
    private static func next(hour: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        let candidate = calendar.date(from: components) ?? now
        return candidate > now
            ? candidate
            : calendar.date(byAdding: .day, value: 1, to: candidate) ?? now
    }
}
