import SwiftUI
import GoelCore

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

    private var isEdit: Bool { mode != .add }

    private var validCount: Int { TrackerList.parse(text).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? L10n.t("Edit Tracker") : L10n.t("Add Trackers"))
                .scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
            Text(isEdit ? L10n.t("Change the announce URL. The torrent re-announces right away.")
                        : L10n.t("One announce URL per line — udp://, http://, https:// or wss://."))
                .scaledFont(size: Theme.TextSize.meta).foregroundStyle(.secondary)
            editor
            footer
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { if case .edit(let url) = mode { text = url } }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .scaledFont(size: Theme.TextSize.meta, design: .monospaced)
            .frame(height: isEdit ? 44 : 140)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Color.secondary.opacity(0.3)))
            .accessibilityLabel(L10n.t("Tracker URLs"))
    }

    private var footer: some View {
        HStack {
            Text(L10n.t("%d valid", validCount))
                .scaledFont(size: Theme.TextSize.meta).foregroundStyle(validCount > 0 ? Theme.green : .secondary)
            Spacer()
            Button(L10n.t("Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEdit ? L10n.t("Save") : L10n.t("Add")) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(validCount == 0 || (isEdit && validCount != 1))
        }
    }

    private func commit() {
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
