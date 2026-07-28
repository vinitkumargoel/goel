import SwiftUI
import AppKit
import GoelCore

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
                Text(L10n.t("History")).scaledFont(size: 16, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.t("Done")) { vm.isHistoryPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            TextField(L10n.t("Search name or link"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Search history by name or link"))

            if let entries {
                if entries.isEmpty {
                    Text(L10n.t("Nothing here yet — finished downloads are archived automatically."))
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    list
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityLabel(L10n.t("Loading history"))
            }

            HStack {
                Button(L10n.t("Export CSV…")) { exportCSV() }
                    .disabled((entries ?? []).isEmpty)
                Spacer()
                Button(L10n.t("Clear History"), role: .destructive) {
                    vm.requestConfirm(
                        title: L10n.t("Clear the download history?"),
                        message: L10n.t("This removes every archived entry. Files on disk are not touched."),
                        confirmTitle: L10n.t("Clear History"),
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
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.completedAt.formatted(date: .abbreviated, time: .shortened)
                     + (entry.totalBytes.map { " · \($0.byteString)" } ?? ""))
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.secondary)
            }
            .a11yGroup(label: entry.name,
                       value: A11y.sentence(
                        entry.completedAt.formatted(date: .abbreviated, time: .shortened),
                        entry.totalBytes.map(A11y.bytes)))
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                iconButton("arrow.down.circle", help: L10n.t("Download again"),
                           label: L10n.t("Download “%@” again", entry.name)) {
                    vm.redownload(entry)
                }
                iconButton("magnifyingglass.circle", help: L10n.t("Reveal in Finder"),
                           label: L10n.t("Reveal “%@” in Finder", entry.name)) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.savePath)])
                }
                .disabled(!FileManager.default.fileExists(atPath: entry.savePath))
                iconButton("doc.on.doc", help: L10n.t("Copy link"),
                           label: L10n.t("Copy link for “%@”", entry.name)) {
                    vm.copyToPasteboard(entry.locator)
                }
                iconButton("trash", help: L10n.t("Remove entry"),
                           label: L10n.t("Remove “%@” from history", entry.name)) {
                    vm.deleteHistoryEntry(entry.id)
                    entries?.removeAll { $0.id == entry.id }
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }

    private func iconButton(_ symbol: String, help: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .help(help)
        .a11yButton(label)
    }

    private func exportCSV() {
        guard let url = FilePicker.save(name: "GoelDownloader-history.csv", type: .commaSeparatedText) else { return }
        vm.exportHistoryCSV(entries ?? [], to: url)
    }
}

struct ScheduledStartOption: Identifiable {
    let id: String
    let label: String
    let date: () -> Date

    static var presets: [ScheduledStartOption] {
        [
            ScheduledStartOption(id: "1h", label: L10n.t("In 1 Hour")) {
                Date().addingTimeInterval(3600)
            },
            ScheduledStartOption(id: "4h", label: L10n.t("In 4 Hours")) {
                Date().addingTimeInterval(4 * 3600)
            },
            ScheduledStartOption(id: "night", label: L10n.t("Tonight at 2 AM")) { Self.next(hour: 2) },
            ScheduledStartOption(id: "morning", label: L10n.t("Tomorrow at 8 AM")) { Self.next(hour: 8) },
        ]
    }

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
