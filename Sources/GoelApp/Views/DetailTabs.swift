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
                .a11yButton(L10n.t("Copy %@", L10n.midSentence(L10n.t(key))))
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
                KVRow(key: L10n.t("Info hash"), value: task.displayInfoHash ?? "—",
                      copyable: task.displayInfoHash != nil)
                KVRow(key: L10n.t("Peers"), value: L10n.t("%d connected", task.connectionCount))
                KVRow(key: L10n.t("Seeds"), value: task.seedCount.map { L10n.t("%d available", $0) } ?? "—")
                KVRow(key: L10n.t("Leechers"), value: "\(task.leecherCount)")
                KVRow(key: L10n.t("Protocol"), value: torrentProtocol)
                KVRow(key: L10n.t("Encryption"), value: encryptionText)
                if task.sequentialDownload == true {
                    KVRow(key: L10n.t("Piece order"), value: L10n.t("Sequential (streaming)"), valueColor: Theme.teal)
                }
                if let limit = task.seedRatioLimit, limit > 0 {
                    KVRow(key: L10n.t("Seed until ratio"), value: String(format: "%.1f", limit),
                          valueColor: Theme.teal)
                }
                trackerSection
            } else {
                KVRow(key: L10n.t("URL"), value: task.sourceLocator, copyable: true)
                KVRow(key: L10n.t("MIME type"), value: task.remoteInfo?.mimeType ?? "—")
                KVRow(key: L10n.t("Server"), value: task.remoteInfo?.server ?? "—")
                KVRow(key: L10n.t("Range support"), value: rangeText, valueColor: rangeColor)
                KVRow(key: L10n.t("Segments"), value: L10n.t("%d connections", max(1, task.connectionCount)))
                KVRow(key: L10n.t("Resumable"), value: task.resumeData != nil ? L10n.t("Yes") : L10n.t("Pending"),
                      valueColor: task.resumeData != nil ? Theme.green : .secondary)
                KVRow(key: L10n.t("ETag"), value: task.remoteInfo?.etag ?? "—")
                KVRow(key: L10n.t("Checksum"), value: checksumValue, valueColor: checksumColor)
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
        case "require": return L10n.t("Required")
        case "disable": return L10n.t("Disabled")
        default: return L10n.t("Enabled (prefer)")
        }
    }

    @ViewBuilder private var trackerSection: some View {
        if let live = task.trackers, !live.isEmpty {
            SectionLabel(text: L10n.t("Trackers · %d", live.count))
            ForEach(live) { tracker in
                TrackerRow(tracker: tracker)
                Divider()
            }
        } else if !magnetTrackers.isEmpty {
            SectionLabel(text: L10n.t("Trackers · %d", magnetTrackers.count))
            ForEach(magnetTrackers, id: \.self) { url in
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(URLComponents(string: url)?.host ?? url)
                        .scaledFont(size: 11.5, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(L10n.t("idle")).scaledFont(size: 10).foregroundStyle(.tertiary)
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
        case .some(true): return L10n.t("Yes (Accept-Ranges)")
        case .some(false): return L10n.t("No — single connection")
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
        guard let checksum = task.expectedChecksum else { return L10n.t("Not provided") }
        let algorithm = checksum.algorithm.displayName
        if case .failed(.checksumMismatch) = task.status { return L10n.t("%@ mismatch", algorithm) }
        switch task.status {
        case .verifying: return L10n.t("Verifying (%@)…", algorithm)
        case .completed: return L10n.t("%@ verified", algorithm)
        default: return L10n.t("%@ pending", algorithm)
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
            label: A11y.sentence(L10n.t("Tracker"), tracker.host),
            value: A11y.sentence(
                L10n.t(tracker.statusLabel),
                tracker.seeds.map { L10n.t("%d seeds", $0) },
                tracker.leeches.map { L10n.t("%d leechers", $0) },
                tracker.message.isEmpty ? nil : tracker.message))
        .accessibilityAction(named: Text(L10n.t("Copy tracker URL"))) { vm.copyToPasteboard(tracker.url) }
        .contextMenu {
            Button(L10n.t("Copy Tracker URL")) { vm.copyToPasteboard(tracker.url) }
            if tracker.url.hasPrefix("http"), let url = URL(string: tracker.url) {
                Button(L10n.t("Open in Browser")) { NSWorkspace.shared.open(url) }
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
                SectionLabel(text: L10n.t("Piece map"))
                if task.status == .requestingMetadata {
                    Text(L10n.t("Waiting for metadata…"))
                        .scaledFont(size: 11.5).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ProgressView(value: task.fractionCompleted).tint(Theme.accent).padding(.vertical, 6)
                }
            } else {
                let have = buckets.filter { $0 >= 0.999 }.count
                let partial = buckets.filter { $0 > 0 && $0 < 0.999 }.count
                SectionLabel(text: L10n.t("Piece map · %1$@/%2$@ complete", String(have), String(buckets.count)))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(13), spacing: 3), count: 16), spacing: 3) {
                    ForEach(buckets.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bucketColor(buckets[i]))
                            .frame(width: 13, height: 13)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.t("Piece map"))
                .accessibilityValue(
                    L10n.t("%1$@ of %2$@ blocks complete, %3$@ in progress, %4$@ not started",
                           String(have), String(buckets.count), String(partial),
                           String(buckets.count - have - partial)))
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
                SectionLabel(text: L10n.t("Overall progress"))
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
                .a11yGroup(label: L10n.t("Overall progress"), value: task.accessibilityProgressValue)
            } else {
                SectionLabel(text: L10n.t("%d parallel segments", live.count))
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
            legendItem(Theme.green, L10n.t("Have"))
            legendItem(Theme.accent, L10n.t("Downloading"))
            legendItem(Color.primary.opacity(0.08), L10n.t("Missing"))
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
                Text(L10n.t("Single-file HTTP download — the one-file case of the unified multi-file model."))
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
            .a11yButton(wanted ? L10n.t("Skip %@", name) : L10n.t("Download %@", name))
            .accessibilityValue(wanted ? L10n.t("Included") : L10n.t("Skipped"))

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
                    .button(L10n.t(p.displayName)) { vm.setFilePriority(p, fileID: fileID, task: task.id) }
                }, menuWidth: 130) { open in
                    HStack(spacing: 3) {
                        Text(L10n.t(priority.displayName))
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
                .accessibilityLabel(L10n.t("Priority for %@", name))
                .accessibilityValue(L10n.t(priority.displayName))
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
        let seeds = task.seedCount.map { " · " + L10n.t("%d seeds", $0) } ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L10n.t("%d peers", task.connectionCount) + seeds)
            if live.isEmpty {
                emptyConnections(L10n.t("No active peers"))
            } else {
                connHeader(left: L10n.t("Peer"), trailing: "↑")
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
        let label = host.isEmpty ? L10n.t("HTTP connections") : L10n.t("HTTP connections") + " · \(host)"
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            if live.isEmpty {
                emptyConnections(L10n.t("No active connections"))
            } else {
                connHeader(left: L10n.t("Segment"), trailing: L10n.t("done"))
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
