import SwiftUI
import GoelCore

/// The right detail panel with the five tabs (General, Details, Progress, Files,
/// Connections), mirroring the mockup.
struct DetailPanelView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        Group {
            if let task = vm.selectedTask {
                content(for: task)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func content(for task: DownloadTask) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 11) {
                FileTypeIcon(type: task.fileType, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text("\(task.status.displayName) · \(task.kind == .torrent ? "BitTorrent" : "HTTP")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider()

            // Tabs
            Picker("", selection: $vm.detailTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch vm.detailTab {
                    case .general: GeneralTab(task: task)
                    case .details: DetailsTab(task: task)
                    case .progress: ProgressTab(task: task)
                    case .files: FilesTab(task: task)
                    case .connections: ConnectionsTab(task: task)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No selection").font(.system(size: 14)).foregroundStyle(.secondary)
            Text("Select a download to see details, progress, files, and connections.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }
}

// MARK: - Shared rows

/// A key/value row used across the detail tabs.
private struct KVRow: View {
    let key: String
    let value: String
    var copyable: Bool = false
    var valueColor: Color = .primary
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
            if copyable {
                Button {
                    vm.copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        Divider()
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Big progress
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int((task.fractionCompleted * 100).rounded()))%")
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                Spacer()
                Text("\(task.bytesDownloaded.byteString) of \(task.totalBytes?.byteString ?? "—")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: task.fractionCompleted)
                .tint(task.progressTint)
                .padding(.vertical, 7)
            HStack {
                Text("↓ \(task.downloadSpeed.speedString)")
                Spacer()
                Text("↑ \(task.uploadSpeed.speedString)")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            if case .failed(let error) = task.status {
                Text("⚠ \(error.message)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 10)
            }

            Spacer().frame(height: 12)

            KVRow(key: "Save path", value: task.savePath, copyable: true)
            KVRow(key: "Downloaded", value: task.bytesDownloaded.byteString)
            if task.kind == .torrent {
                KVRow(key: "Uploaded", value: task.bytesUploaded.byteString)
                KVRow(key: "Share ratio", value: String(format: "%.2f", task.shareRatio))
            }
            KVRow(key: "Added", value: task.addedString)
            KVRow(key: "Priority", value: task.priority.displayName)
            KVRow(key: "Source", value: task.sourceLocator, copyable: true)
        }
    }
}

// MARK: - Details

private struct DetailsTab: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: "Info hash", value: task.infoHash ?? "—", copyable: task.infoHash != nil)
                KVRow(key: "Pieces", value: pieceText)
                KVRow(key: "Peers", value: "\(task.connectionCount) connected")
                KVRow(key: "Protocol", value: "BitTorrent v1 · DHT · PeX")
                KVRow(key: "Encryption", value: "Enabled (prefer)")
                SectionLabel(text: "Trackers")
                Text("udp://tracker.opentrackr.org:1337\nudp://open.demonii.com:1337\nudp://tracker.torrent.eu.org:451")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                KVRow(key: "URL", value: task.sourceLocator, copyable: true)
                KVRow(key: "Server", value: "HTTP/2")
                KVRow(key: "Range support", value: "Yes (Accept-Ranges)", valueColor: Theme.green)
                KVRow(key: "Segments", value: "\(max(1, task.connectionCount)) connections")
                KVRow(key: "Resumable", value: task.resumeData != nil ? "Yes" : "Pending", valueColor: Theme.green)
                KVRow(key: "Checksum", value: isFailed ? "Mismatch" : "SHA-256 pending",
                      valueColor: isFailed ? Theme.red : .primary)
            }
        }
    }

    private var pieceText: String {
        guard let total = task.totalBytes else { return "—" }
        let pieceSize: Int64 = 4 * 1024 * 1024
        return "\(max(1, Int((total + pieceSize - 1) / pieceSize))) × 4 MB"
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }
}

// MARK: - Progress (segments / piece map)

private struct ProgressTab: View {
    let task: DownloadTask

    var body: some View {
        if task.kind == .torrent {
            pieceMap
        } else {
            segments
        }
    }

    private var pieceMap: some View {
        let total = 120
        let filled = Int(Double(total) * task.fractionCompleted)
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Piece map · \(filled)/\(total) pieces")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(13), spacing: 3), count: 16), spacing: 3) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pieceColor(i, filled: filled))
                        .frame(width: 13, height: 13)
                }
            }
            legend
        }
    }

    private func pieceColor(_ i: Int, filled: Int) -> Color {
        if task.status == .requestingMetadata { return Theme.orange.opacity(0.7) }
        if i < filled { return Theme.green }
        if i == filled && task.status == .downloading { return Theme.accent }
        return Color.primary.opacity(0.08)
    }

    private var segments: some View {
        let count = max(1, task.connectionCount)
        let pct = task.fractionCompleted
        return VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "\(count) parallel segments")
            ForEach(0..<count, id: \.self) { i in
                let jitter = task.status == .downloading ? Double((i * 7) % 23 - 11) / 100 : 0
                let sp = max(0, min(1, pct + jitter))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Segment \(i + 1)")
                        Spacer()
                        Text("\(Int((sp * 100).rounded()))%")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    ProgressView(value: sp)
                        .tint(task.status == .completed ? Theme.green : Theme.accent)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Theme.green, "Have")
            legendItem(Theme.accent, "Downloading")
            legendItem(Color.primary.opacity(0.08), "Missing")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 12)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

// MARK: - Files (per-file selection + priority)

private struct FilesTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        if task.files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                fileRow(name: task.name, fraction: task.fractionCompleted,
                        size: task.totalBytes ?? 0, wanted: true, fileID: nil, priority: .normal)
                Text("Single-file HTTP download — the one-file case of the unified multi-file model.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(task.files) { file in
                    fileRow(name: file.name, fraction: file.fractionCompleted,
                            size: file.length, wanted: file.isWanted,
                            fileID: file.id, priority: file.priority)
                    Divider()
                }
            }
        }
    }

    private func fileRow(name: String, fraction: Double, size: Int64, wanted: Bool,
                         fileID: Int?, priority: FilePriority) -> some View {
        HStack(spacing: 9) {
            Button {
                guard let fileID else { return }
                vm.setFilePriority(wanted ? .skip : .normal, fileID: fileID, task: task.id)
            } label: {
                Image(systemName: wanted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(wanted ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(fileID == nil)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                ProgressView(value: fraction).tint(Theme.green)
            }

            Text(size.byteString)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let fileID {
                Menu(priority.displayName) {
                    ForEach([FilePriority.skip, .low, .normal, .high], id: \.self) { p in
                        Button(p.displayName) { vm.setFilePriority(p, fileID: fileID, task: task.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10))
                .foregroundStyle(priority == .high ? Theme.orange : Color.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Connections

private struct ConnectionsTab: View {
    let task: DownloadTask

    var body: some View {
        if task.kind == .torrent {
            peers
        } else {
            httpConnections
        }
    }

    private var peers: some View {
        let sample: [(String, String, Double, Double)] = [
            ("🇳🇱", "185.21.216.x:51413", 2.1, 0.4),
            ("🇩🇪", "92.118.37.x:6881", 1.8, 0.9),
            ("🇺🇸", "73.158.44.x:6889", 1.2, 0.2),
            ("🇯🇵", "203.0.113.x:51820", 0.9, 0.6),
            ("🇫🇷", "45.83.91.x:6881", 0.6, 1.1),
        ]
        let active = task.status == .downloading || task.status == .seeding
        let shown = Array(sample.prefix(max(1, min(sample.count, task.connectionCount))))
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "\(task.connectionCount) peers")
            connHeader(left: "Peer")
            ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                connRow(label: "\(p.0) \(p.1)",
                        down: active ? p.2 : 0, up: active ? p.3 : 0)
            }
        }
    }

    private var httpConnections: some View {
        let count = max(1, task.connectionCount)
        let active = task.status == .downloading
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "HTTP connections")
            connHeader(left: "Segment")
            ForEach(0..<count, id: \.self) { i in
                connRow(label: "conn #\(i + 1) · keep-alive",
                        down: active ? Double(3 + (i * 4) % 9) : 0, up: 0)
            }
        }
    }

    private func connHeader(left: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(left)
                Spacer()
                Text("↓").frame(width: 50, alignment: .trailing)
                Text("↑").frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func connRow(label: String, down: Double, up: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: "%.1f", down)).frame(width: 50, alignment: .trailing).foregroundStyle(Theme.green)
                Text(String(format: "%.1f", up)).frame(width: 50, alignment: .trailing).foregroundStyle(Theme.teal)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .padding(.vertical, 7)
            Divider()
        }
    }
}
