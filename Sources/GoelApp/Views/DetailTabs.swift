import SwiftUI
import AppKit
import GoelCore

struct KVRow: View {
    let key: String
    let value: String
    var copyable: Bool = false
    var valueColor: Color = .primary
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .top) {
            Text(key).scaledFont(size: 12).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .scaledFont(size: 12)
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
                .a11yButton("Copy \(key.lowercased())")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(key)
        .accessibilityValue(value)
        .padding(.vertical, 7)
        Divider()
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .scaledFont(size: 10.5, weight: .bold)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct DetailsTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.kind == .torrent {
                KVRow(key: "Info hash", value: task.displayInfoHash ?? "—",
                      copyable: task.displayInfoHash != nil)
                KVRow(key: "Peers", value: "\(task.connectionCount) connected")
                KVRow(key: "Seeds", value: task.seedCount.map { "\($0) available" } ?? "—")
                KVRow(key: "Leechers", value: "\(task.leecherCount)")
                KVRow(key: "Protocol", value: torrentProtocol)
                KVRow(key: "Encryption", value: encryptionText)
                if task.sequentialDownload == true {
                    KVRow(key: "Piece order", value: "Sequential (streaming)", valueColor: Theme.teal)
                }
                if let limit = task.seedRatioLimit, limit > 0 {
                    KVRow(key: "Seed until ratio", value: String(format: "%.1f", limit),
                          valueColor: Theme.teal)
                }
                trackerSection
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

    @ViewBuilder private var trackerSection: some View {
        if let live = task.trackers, !live.isEmpty {
            SectionLabel(text: "Trackers · \(live.count)")
            ForEach(live) { tracker in
                TrackerRow(tracker: tracker)
                Divider()
            }
        } else if !magnetTrackers.isEmpty {
            SectionLabel(text: "Trackers · \(magnetTrackers.count)")
            ForEach(magnetTrackers, id: \.self) { url in
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(URLComponents(string: url)?.host ?? url)
                        .scaledFont(size: 11.5, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("idle").scaledFont(size: 10).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private var magnetTrackers: [String] {
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

struct TrackerRow: View {
    let tracker: TorrentTracker
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.host)
                    .scaledFont(size: 11.5, design: .monospaced)
                    .lineLimit(1).truncationMode(.middle)
                if !tracker.message.isEmpty {
                    Text(tracker.message)
                        .scaledFont(size: 10).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let s = tracker.seeds {
                Text("\(s)S").scaledFont(size: 10.5, monospacedDigit: true).foregroundStyle(Theme.green)
            }
            if let l = tracker.leeches {
                Text("\(l)L").scaledFont(size: 10.5, monospacedDigit: true).foregroundStyle(Theme.orange)
            }
            Text(tracker.statusLabel)
                .scaledFont(size: 9.5, weight: .semibold)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .a11yGroup(
            label: A11y.sentence("Tracker", tracker.host),
            value: A11y.sentence(
                tracker.statusLabel,
                tracker.seeds.map { "\($0) seeds" },
                tracker.leeches.map { "\($0) leechers" },
                tracker.message.isEmpty ? nil : tracker.message))
        .accessibilityAction(named: Text("Copy tracker URL")) { vm.copyToPasteboard(tracker.url) }
        .contextMenu {
            Button("Copy Tracker URL") { vm.copyToPasteboard(tracker.url) }
            if tracker.url.hasPrefix("http"), let url = URL(string: tracker.url) {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var statusColor: Color {
        switch tracker.status {
        case .working:  return Theme.green
        case .updating: return Theme.accent
        case .error:    return Theme.red
        case .inactive: return .secondary
        }
    }
}

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
        let buckets = task.pieceAvailability ?? []
        return VStack(alignment: .leading, spacing: 0) {
            if buckets.isEmpty {
                SectionLabel(text: "Piece map")
                if task.status == .requestingMetadata {
                    Text("Waiting for metadata…")
                        .scaledFont(size: 11.5).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ProgressView(value: task.fractionCompleted).tint(Theme.accent).padding(.vertical, 6)
                }
            } else {
                let have = buckets.filter { $0 >= 0.999 }.count
                let partial = buckets.filter { $0 > 0 && $0 < 0.999 }.count
                SectionLabel(text: "Piece map · \(have)/\(buckets.count) complete")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(13), spacing: 3), count: 16), spacing: 3) {
                    ForEach(buckets.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bucketColor(buckets[i]))
                            .frame(width: 13, height: 13)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Piece map")
                .accessibilityValue(
                    "\(have) of \(buckets.count) blocks complete, "
                    + "\(partial) in progress, "
                    + "\(buckets.count - have - partial) not started")
            }
            legend
        }
    }

    private func bucketColor(_ fraction: Double) -> Color {
        if fraction >= 0.999 { return Theme.green }
        if fraction > 0 { return Theme.accent.opacity(0.3 + 0.6 * fraction) }
        return Color.primary.opacity(0.08)
    }

    private var segments: some View {
        let live = task.connections ?? []
        return VStack(alignment: .leading, spacing: 9) {
            if live.isEmpty {
                SectionLabel(text: "Overall progress")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(task.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(Int((task.fractionCompleted * 100).rounded()))%")
                    }
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    ProgressView(value: task.fractionCompleted)
                        .tint(task.status == .completed ? Theme.green : Theme.accent)
                }
                .a11yGroup(label: "Overall progress", value: task.accessibilityProgressValue)
            } else {
                SectionLabel(text: "\(live.count) parallel segments")
                ForEach(live) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(segment.label)
                            Spacer()
                            Text("\(Int((segment.progress * 100).rounded()))%")
                        }
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        ProgressView(value: segment.progress)
                            .tint(segment.progress >= 1 ? Theme.green : Theme.accent)
                    }
                    .a11yGroup(label: segment.label, value: A11y.percent(segment.progress))
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
        .scaledFont(size: 11)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .a11yDecorative()
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

struct FilesTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        if task.files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                fileRow(name: task.name, fraction: task.fractionCompleted,
                        size: task.totalBytes ?? 0, wanted: true, fileID: nil, priority: .normal)
                Text("Single-file HTTP download — the one-file case of the unified multi-file model.")
                    .scaledFont(size: 11.5)
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
            .a11yButton(wanted ? "Skip \(name)" : "Download \(name)")
            .accessibilityValue(wanted ? "Included" : "Skipped")

            VStack(alignment: .leading, spacing: 4) {
                Text(name).scaledFont(size: 12).lineLimit(1).truncationMode(.middle)
                ProgressView(value: fraction).tint(Theme.green)
            }
            .a11yGroup(label: name, value: A11y.percent(fraction))

            Text(size.byteString)
                .scaledFont(size: 11, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .accessibilityLabel(A11y.bytes(size))

            if let fileID {
                ActionMenu(items: [FilePriority.skip, .low, .normal, .high].map { p in
                    .button(p.displayName) { vm.setFilePriority(p, fileID: fileID, task: task.id) }
                }, menuWidth: 130) { open in
                    HStack(spacing: 3) {
                        Text(priority.displayName)
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    }
                    .scaledFont(size: 10)
                    .foregroundStyle(priority == .high ? Theme.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(open ? Color.primary.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Priority for \(name)")
                .accessibilityValue(priority.displayName)
            }
        }
        .padding(.vertical, 8)
    }
}

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
                    let adapter = segment.adapterLabel.map { " · \($0)" } ?? ""
                    connRow(label: "\(segment.label)\(adapter) · \(segment.detail)",
                            subtitle: segment.adapterId,
                            down: segment.downloadSpeed,
                            trailing: "\(Int((segment.progress * 100).rounded()))%",
                            trailingColor: .secondary)
                }
            }
        }
    }

    private func emptyConnections(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11.5)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private func connHeader(left: String, trailing: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(left)
                Spacer()
                Text("↓").frame(width: 50, alignment: .trailing)
                Text(trailing).frame(width: 56, alignment: .trailing)
            }
            .scaledFont(size: 10.5, weight: .semibold)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
            .a11yDecorative()
            Divider()
        }
    }

    private func connRow(label: String, subtitle: String?, down: Double,
                         trailing: String, trailingColor: Color) -> some View {
        connRowBody(label: label, subtitle: subtitle, down: down,
                    trailing: trailing, trailingColor: trailingColor)
            .a11yGroup(
                label: A11y.sentence(label, subtitle.flatMap { $0.isEmpty || $0 == "peer" ? nil : $0 }),
                value: A11y.sentence(A11y.speed(down), trailing))
    }

    private func connRowBody(label: String, subtitle: String?, down: Double,
                             trailing: String, trailingColor: Color) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).scaledFont(size: 11.5).lineLimit(1).truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty, subtitle != "peer" {
                        Text(subtitle).scaledFont(size: 10).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                Text(down > 0 ? down.speedString : "—")
                    .frame(width: 64, alignment: .trailing).foregroundStyle(Theme.green)
                Text(trailing).frame(width: 56, alignment: .trailing).foregroundStyle(trailingColor)
            }
            .scaledFont(size: 11.5, monospacedDigit: true)
            .padding(.vertical, 7)
            Divider()
        }
    }
}

private extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
}
