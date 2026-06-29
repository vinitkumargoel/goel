import SwiftUI
import GoelCore

// The five detail-panel tab bodies (General, Details, Progress, Files,
// Connections) and their shared rows. Split out of `DetailPanelView.swift` so the
// panel shell stays small; each tab is rendered by `DetailPanelView.content`.

// MARK: - Shared rows

/// A key/value row used across the detail tabs.
struct KVRow: View {
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

struct SectionLabel: View {
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

struct GeneralTab: View {
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

struct DetailsTab: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: "Info hash", value: task.infoHash ?? "—", copyable: task.infoHash != nil)
                KVRow(key: "Pieces", value: pieceText)
                KVRow(key: "Peers", value: "\(task.connectionCount) connected")
                KVRow(key: "Seeds", value: "\(task.seedCount) available")
                KVRow(key: "Protocol", value: "BitTorrent v1 · DHT · PeX")
                KVRow(key: "Encryption", value: "Enabled (prefer)")
                SectionLabel(text: "Trackers")
                Text("udp://tracker.opentrackr.org:1337\nudp://open.demonii.com:1337\nudp://tracker.torrent.eu.org:451")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                KVRow(key: "URL", value: task.sourceLocator, copyable: true)
                KVRow(key: "MIME type", value: mimeType)
                // TODO: "Server", "Range support" and "ETag" are illustrative
                // placeholders — the frozen core model doesn't surface live response
                // headers yet. Wire these from real metadata when the engine exposes it.
                KVRow(key: "Server", value: "nginx · HTTP/2")
                KVRow(key: "Range support", value: "Yes (Accept-Ranges)", valueColor: Theme.green)
                KVRow(key: "Segments", value: "\(max(1, task.connectionCount)) connections")
                KVRow(key: "Resumable", value: task.resumeData != nil ? "Yes" : "Pending", valueColor: Theme.green)
                KVRow(key: "ETag", value: "\"a3f9-62b1c0\"")
                KVRow(key: "Checksum", value: checksumValue, valueColor: checksumColor)
            }
        }
    }

    /// MIME type inferred from the file category, mirroring the design's `mimeFor()`.
    private var mimeType: String {
        switch task.fileType {
        case .iso: return "application/x-iso9660-image"
        case .video: return "video/x-matroska"
        case .archive: return "application/gzip"
        case .magnet: return "application/x-bittorrent"
        case .app, .doc: return "application/octet-stream"
        }
    }

    private var pieceText: String {
        guard let total = task.totalBytes else { return "—" }
        let pieceSize: Int64 = 4 * 1024 * 1024
        return "\(max(1, Int((total + pieceSize - 1) / pieceSize))) × 4 MB"
    }

    /// Reflects the integrity-check state for the HTTP "Checksum" row.
    private var checksumValue: String {
        guard let checksum = task.expectedChecksum else { return "Not provided" }
        if case .failed(.checksumMismatch) = task.status { return "\(checksum.algorithm.displayName) mismatch" }
        switch task.status {
        case .verifying: return "Verifying (\(checksum.algorithm.displayName))…"
        case .completed: return "\(checksum.algorithm.displayName) verified"
        default: return "\(checksum.algorithm.displayName) pending"
        }
    }

    private var checksumColor: Color {
        guard task.expectedChecksum != nil else { return .secondary }
        if case .failed(.checksumMismatch) = task.status { return Theme.red }
        if case .completed = task.status { return Theme.green }
        return .primary
    }
}

// MARK: - Progress (segments / piece map)

struct ProgressTab: View {
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

struct FilesTab: View {
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

struct ConnectionsTab: View {
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
        // No `max(1, …)` floor: an idle/paused/completed task has zero live peers,
        // so the row count must match the header count (and a completed transfer
        // shows none) rather than always forcing one sample row.
        let shown = Array(sample.prefix(min(sample.count, task.connectionCount)))
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "\(task.connectionCount) peers · \(task.seedCount) seeds")
            if shown.isEmpty {
                emptyConnections("No active peers")
            } else {
                connHeader(left: "Peer", trailing: "↑")
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    connRow(label: "\(p.0) \(p.1)",
                            down: active ? p.2 : 0,
                            trailing: String(format: "%.1f", active ? p.3 : 0),
                            trailingColor: Theme.teal)
                }
            }
        }
    }

    private var httpConnections: some View {
        // No floor: a completed/paused HTTP task reports `connectionCount == 0`,
        // so the panel shows no open connections instead of a phantom one.
        let count = task.connectionCount
        let active = task.status == .downloading
        let host = URLComponents(string: task.sourceLocator)?.host ?? ""
        let label = host.isEmpty ? "HTTP connections" : "HTTP connections · \(host)"
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            if count == 0 {
                emptyConnections("No active connections")
            } else {
                connHeader(left: "Segment", trailing: "range")
                ForEach(0..<count, id: \.self) { i in
                    connRow(label: "conn #\(i + 1) · keep-alive",
                            down: active ? Double(3 + (i * 4) % 9) : 0,
                            trailing: "\(i * 100 / count)–\((i + 1) * 100 / count)%",
                            trailingColor: .secondary)
                }
            }
        }
    }

    private func emptyConnections(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    /// Header for the two-column transfer table. `trailing` is the third column's
    /// label — "↑" (upload speed) for peers, "range" (byte range) for HTTP segments.
    private func connHeader(left: String, trailing: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(left)
                Spacer()
                Text("↓").frame(width: 50, alignment: .trailing)
                Text(trailing).frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
            Divider()
        }
    }

    /// A transfer row. The third column is `trailing` (a peer's upload speed, or an
    /// HTTP segment's byte range) and is tinted with `trailingColor`.
    private func connRow(label: String, down: Double, trailing: String, trailingColor: Color) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format: "%.1f", down)).frame(width: 50, alignment: .trailing).foregroundStyle(Theme.green)
                Text(trailing).frame(width: 56, alignment: .trailing).foregroundStyle(trailingColor)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .padding(.vertical, 7)
            Divider()
        }
    }
}

// MARK: - Derived display values

extension DownloadTask {
    /// A representative seed count for the swarm display. The frozen core model
    /// carries no live seed figure, so this scales off the (real, fluctuating)
    /// live peer count and collapses to zero whenever the swarm is down
    /// (paused / completed / idle), matching the design's "N peers · M seeds".
    var seedCount: Int { connectionCount * 3 }
}
