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

            TaskSpeedGraph(taskID: task.id)

            if case .failed(let error) = task.status {
                Text("⚠ \(error.message)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 10)
            }

            if task.scanVerdict == "flagged" {
                Text("⚠ Antivirus flagged this file — inspect it before opening.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
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
            if let verdict = task.scanVerdict {
                KVRow(key: "Antivirus", value: verdict == "clean" ? "Clean" : "Flagged",
                      valueColor: verdict == "clean" ? Theme.green : Theme.orange)
            }
            if let cap = task.speedLimitBytesPerSec, cap > 0 {
                KVRow(key: "Speed limit", value: Double(cap).speedString)
            }
            if let startAt = task.scheduledAt, task.status == .paused {
                KVRow(key: "Scheduled start",
                      value: startAt.formatted(date: .abbreviated, time: .shortened),
                      valueColor: Theme.accent)
            }
            if let mirrors = task.mirrors, !mirrors.isEmpty {
                KVRow(key: "Mirrors", value: "\(mirrors.count) alternative source\(mirrors.count == 1 ? "" : "s")")
            }
            KVRow(key: "Source", value: task.sourceLocator, copyable: true)
        }
    }
}

// MARK: - Details

struct DetailsTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: "Info hash", value: task.infoHash ?? "—", copyable: task.infoHash != nil)
                KVRow(key: "Peers", value: "\(task.connectionCount) connected")
                KVRow(key: "Seeds", value: task.seedCount.map { "\($0) available" } ?? "—")
                KVRow(key: "Protocol", value: torrentProtocol)
                KVRow(key: "Encryption", value: encryptionText)
                if task.sequentialDownload == true {
                    KVRow(key: "Piece order", value: "Sequential (streaming)", valueColor: Theme.teal)
                }
                if !trackers.isEmpty {
                    SectionLabel(text: "Trackers")
                    Text(trackers.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                KVRow(key: "URL", value: task.sourceLocator, copyable: true)
                KVRow(key: "MIME type", value: task.remoteInfo?.mimeType ?? "—")
                KVRow(key: "Server", value: task.remoteInfo?.server ?? "—")
                KVRow(key: "Range support", value: rangeText, valueColor: rangeColor)
                KVRow(key: "Segments", value: "\(max(1, task.connectionCount)) connections")
                KVRow(key: "Resumable", value: task.resumeData != nil ? "Yes" : "Pending",
                      valueColor: task.resumeData != nil ? Theme.green : .secondary)
                KVRow(key: "ETag", value: task.remoteInfo?.etag ?? "—")
                KVRow(key: "Checksum", value: checksumValue, valueColor: checksumColor)
            }
        }
    }

    /// Real feature flags from the active BitTorrent settings.
    private var torrentProtocol: String {
        var parts = ["BitTorrent"]
        if vm.settings.btEnableDHT { parts.append("DHT") }
        if vm.settings.btEnablePeX { parts.append("PeX") }
        if vm.settings.btEnableLPD { parts.append("LPD") }
        return parts.joined(separator: " · ")
    }

    private var encryptionText: String {
        switch vm.settings.btEncryptionMode {
        case "require": return "Required"
        case "disable": return "Disabled"
        default: return "Enabled (prefer)"
        }
    }

    /// Tracker URLs parsed from the magnet's `tr=` parameters (real data — a
    /// `.torrent` file's tracker list isn't surfaced by the engine yet).
    private var trackers: [String] {
        guard case .magnet = task.source,
              let components = URLComponents(string: task.sourceLocator) else { return [] }
        return (components.queryItems ?? [])
            .filter { $0.name == "tr" }
            .compactMap(\.value)
    }

    private var rangeText: String {
        switch task.remoteInfo?.acceptRanges {
        case .some(true): return "Yes (Accept-Ranges)"
        case .some(false): return "No — single connection"
        case .none: return "—"
        }
    }

    private var rangeColor: Color {
        switch task.remoteInfo?.acceptRanges {
        case .some(true): return Theme.green
        case .some(false): return Theme.orange
        case .none: return .secondary
        }
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
        let live = task.connections ?? []
        return VStack(alignment: .leading, spacing: 9) {
            if live.isEmpty {
                // No live per-segment data (queued / paused / completed / single
                // stream before the first tick): show the aggregate bar honestly.
                SectionLabel(text: "Overall progress")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(task.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int((task.fractionCompleted * 100).rounded()))%")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    ProgressView(value: task.fractionCompleted)
                        .tint(task.status == .completed ? Theme.green : Theme.accent)
                }
            } else {
                SectionLabel(text: "\(live.count) parallel segments")
                ForEach(live) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(segment.label)
                            Spacer()
                            Text("\(Int((segment.progress * 100).rounded()))%")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        ProgressView(value: segment.progress)
                            .tint(segment.progress >= 1 ? Theme.green : Theme.accent)
                    }
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
                ActionMenu(items: [FilePriority.skip, .low, .normal, .high].map { p in
                    .button(p.displayName) { vm.setFilePriority(p, fileID: fileID, task: task.id) }
                }, menuWidth: 130) { open in
                    HStack(spacing: 3) {
                        Text(priority.displayName)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(priority == .high ? Theme.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(open ? Color.primary.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
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
        let live = task.connections ?? []
        let seeds = task.seedCount.map { " · \($0) seeds" } ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "\(task.connectionCount) peers\(seeds)")
            if live.isEmpty {
                emptyConnections("No active peers")
            } else {
                connHeader(left: "Peer", trailing: "↑")
                ForEach(live) { peer in
                    connRow(label: peer.label,
                            subtitle: peer.detail,
                            down: peer.downloadSpeed,
                            trailing: (peer.uploadSpeed / 1_000_000).oneDecimal,
                            trailingColor: Theme.teal)
                }
            }
        }
    }

    private var httpConnections: some View {
        let live = task.connections ?? []
        let host = URLComponents(string: task.sourceLocator)?.host ?? ""
        let label = host.isEmpty ? "HTTP connections" : "HTTP connections · \(host)"
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            if live.isEmpty {
                emptyConnections("No active connections")
            } else {
                connHeader(left: "Segment", trailing: "done")
                ForEach(live) { segment in
                    connRow(label: "\(segment.label) · \(segment.detail)",
                            subtitle: nil,
                            down: segment.downloadSpeed,
                            trailing: "\(Int((segment.progress * 100).rounded()))%",
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

    /// A transfer row. `down` is a live bytes/sec figure (rendered in MB/s); the
    /// third column is `trailing` (a peer's upload speed, or an HTTP segment's
    /// completion) tinted with `trailingColor`. `subtitle` shows the peer's
    /// client name under the address when present.
    private func connRow(label: String, subtitle: String?, down: Double,
                         trailing: String, trailingColor: Color) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty, subtitle != "peer" {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                Text((down / 1_000_000).oneDecimal)
                    .frame(width: 50, alignment: .trailing).foregroundStyle(Theme.green)
                Text(trailing).frame(width: 56, alignment: .trailing).foregroundStyle(trailingColor)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .padding(.vertical, 7)
            Divider()
        }
    }
}

private extension Double {
    /// "2.4" — one-decimal rendering for the compact MB/s columns.
    var oneDecimal: String { String(format: "%.1f", self) }
}
