import SwiftUI
import AppKit
import GoelCore

/// The torrent's trackers with Add…, and per tracker Copy, Open in Browser, Edit and Remove
/// (in its "…" menu, its context menu and as VoiceOver actions). A magnet without live trackers
/// lists its `tr=` URLs as idle.
struct DetailTrackerSection: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel
    @State private var trackerSheet: TrackerSheetRequest?

    var body: some View {
        let live = task.trackers ?? []
        let magnet = DetailNetworkText.magnetTrackers(task)
        DetailSection(title: L10n.t("Trackers · %d", live.isEmpty ? magnet.count : live.count)) {
            Button(L10n.t("Add…"), systemImage: "plus") { trackerSheet = TrackerSheetRequest(mode: .add) }
                .buttonStyle(.studio(.secondary, size: .small))
                .help(L10n.t("Add tracker URLs to this torrent"))
                .accessibilityLabel(L10n.t("Add trackers"))
        } content: {
            VStack(spacing: 0) {
                if !live.isEmpty {
                    ForEach(live) { tracker in
                        TrackerRow(tracker: tracker,
                                   onEdit: { trackerSheet = TrackerSheetRequest(mode: .edit(tracker.url)) },
                                   onRemove: { vm.removeTrackers([tracker.url], from: task.id) })
                    }
                } else if !magnet.isEmpty {
                    ForEach(magnet, id: \.self) { url in
                        TrackerRow(tracker: TorrentTracker(url: url, status: .inactive))
                    }
                } else {
                    DetailEmptyLine(text: L10n.t("No trackers"))
                }
            }
        }
        .sheet(item: $trackerSheet) { request in
            TrackerEditSheet(mode: request.mode, taskID: task.id).environmentObject(vm)
        }
    }
}

/// One tracker: a status pill, the announce URL and any message, seeds / leechers, and its menu.
struct TrackerRow: View {
    let tracker: TorrentTracker
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let status = DetailNetworkText.trackerStatus(tracker.status)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                StudioPill(status.title, tone: status.tone, showsDot: false)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(tracker.url)
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tracker.url)
                    if !tracker.message.isEmpty {
                        // An error is the one thing worth reading here: red, and allowed a second line.
                        Text(tracker.message)
                            .studioFont(.caption)
                            .foregroundStyle(tracker.status == .error ? Studio.Palette.bad : Studio.Palette.ink3)
                            .lineLimit(tracker.status == .error ? 2 : 1)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(tracker.seeds.map(String.init) ?? "—") / \(tracker.leeches.map(String.init) ?? "—")")
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink3)
                    .help(L10n.t("Seeds / leechers"))
                menu
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .padding(.vertical, 7)
            StudioDivider()
        }
        .contentShape(Rectangle())
        .a11yGroup(
            label: A11y.sentence(L10n.t("Tracker"), tracker.host),
            value: A11y.sentence(
                status.title,
                tracker.seeds.map { L10n.t("%d seeds", $0) },
                tracker.leeches.map { L10n.t("%d leechers", $0) },
                tracker.message.isEmpty ? nil : tracker.message))
        .accessibilityAction(named: Text(L10n.t("Copy tracker URL"))) { vm.copyToPasteboard(tracker.url) }
        .accessibilityAction(named: Text(L10n.t("Edit tracker"))) { onEdit?() }
        .accessibilityAction(named: Text(L10n.t("Remove tracker"))) { onRemove?() }
        .contextMenu { menuItems }
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .studioFont(.ui, size: 12, weight: 650)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(StudioIconButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("More actions"))
        .accessibilityLabel(L10n.t("More actions for %@", tracker.host))
    }

    @ViewBuilder private var menuItems: some View {
        Button(L10n.t("Copy Tracker URL")) { vm.copyToPasteboard(tracker.url) }
        if tracker.url.hasPrefix("http"), let url = URL(string: tracker.url) {
            Button(L10n.t("Open in Browser")) { NSWorkspace.shared.open(url) }
        }
        if let onEdit { Divider(); Button(L10n.t("Edit Tracker…"), action: onEdit) }
        if let onRemove { Button(L10n.t("Remove Tracker"), role: .destructive, action: onRemove) }
    }
}

/// "Add Trackers…" / "Edit Tracker…" for a torrent: one sheet, prefilled when editing.
struct TrackerEditSheet: View {
    enum Mode: Equatable {
        case add
        case edit(String)
    }

    let mode: Mode
    let taskID: DownloadTask.ID
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var editorFocused: Bool

    private var isEdit: Bool { mode != .add }
    private var validCount: Int { TrackerList.parse(text).count }

    var body: some View {
        StudioSheet(title: isEdit ? L10n.t("Edit tracker") : L10n.t("Add trackers"),
                    subtitle: isEdit ? L10n.t("Change the announce URL. The torrent re-announces right away.")
                                     : L10n.t("One announce URL per line — udp://, http://, https:// or wss://."),
                    symbol: "antenna.radiowaves.left.and.right", width: 470) {
            TextEditor(text: $text)
                .studioFont(.monoBody)
                .foregroundStyle(Studio.Palette.ink)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, Studio.Space.s)
                .padding(.vertical, Studio.Space.xs)
                .frame(height: isEdit ? 52 : 140)
                .modifier(StudioFieldChrome(isFocused: editorFocused))
                .accessibilityLabel(L10n.t("Tracker URLs"))
        } footer: {
            StudioSheetFooter(onCancel: { dismiss() }, primaryTitle: isEdit ? L10n.t("Save") : L10n.t("Add"),
                              primaryEnabled: validCount > 0 && !(isEdit && validCount != 1),
                              onPrimary: commit) {
                StudioPill(L10n.t("%d valid", validCount), tone: validCount > 0 ? .good : .neutral)
            }
        }
        .onAppear {
            if case .edit(let url) = mode { text = url }
            editorFocused = true
        }
    }

    private func commit() {
        guard validCount > 0, !(isEdit && validCount != 1) else { return }
        switch mode {
        case .add:
            vm.addTrackers(text, to: taskID)
        case .edit(let old):
            if let new = TrackerList.parse(text).first, new != old { vm.editTracker(old, to: new, on: taskID) }
        }
        dismiss()
    }
}

/// Identifiable wrapper so one `.sheet(item:)` drives both add and edit.
struct TrackerSheetRequest: Identifiable {
    let id = UUID()
    let mode: TrackerEditSheet.Mode
}
