import SwiftUI
import GoelCore

/// Files: the tree with include/skip checks and per-file priority. Before a torrent's metadata
/// arrives (or for a single file) the one row it has and a sentence saying why.
struct DetailFilesTab: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        if task.files.isEmpty {
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                singleRow
                StudioNote(tone: .neutral, symbol: task.kind == .torrent ? "clock" : "doc",
                           message: task.kind == .torrent
                               ? L10n.t("The file list appears once the torrent’s metadata arrives.")
                               : L10n.t("This download is a single file."))
            }
        } else {
            FileTreeView(items: task.files.map(FileTreeItem.init),
                         wanted: Set(task.files.filter(\.isWanted).map(\.id)),
                         onChange: applyWanted) { item in
                if let file = task.files.first(where: { $0.id == item.id }) {
                    DetailFilePriorityMenu(name: file.name, priority: file.priority) { priority in
                        vm.setFilePriority(priority, fileID: file.id, task: task.id)
                    }
                }
            }
        }
    }

    /// Only the files whose state changed are sent, so "Select ▸ All" on a mostly-wanted torrent is cheap.
    private func applyWanted(_ next: Set<Int>) {
        for file in task.files {
            let want = next.contains(file.id)
            guard want != file.isWanted else { continue }
            vm.setFilePriority(want ? .normal : .skip, fileID: file.id, task: task.id)
        }
    }

    /// The download itself as the only row: its check can't be cleared, there being nothing else.
    private var singleRow: some View {
        HStack(spacing: Studio.Space.s) {
            DetailCheckMark(state: .on)
                .opacity(0.45)
                .accessibilityLabel(L10n.t("Download %@", task.compactDisplayName))
                .accessibilityValue(L10n.t("Included"))
            DetailTaskArtwork(task: task, size: .xs)
            VStack(alignment: .leading, spacing: 3) {
                FileNameText(task.compactDisplayName, lineLimit: 1)
                    .studioFont(.body)
                    .foregroundStyle(Studio.Palette.ink)
                StudioLinearProgress(fraction: task.status == .requestingMetadata ? nil : task.fractionCompleted,
                                     tone: StudioProgressTone(task: task), height: 3)
            }
            .a11yGroup(label: task.compactDisplayName, value: A11y.percent(task.fractionCompleted))
            Text((task.totalBytes ?? 0).byteString)
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink2)
                .accessibilityLabel(A11y.bytes(task.totalBytes ?? 0))
        }
        .padding(.horizontal, Studio.Space.s)
        .padding(.vertical, 7)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
    }
}

/// A file's priority as a small chip menu: Skip, Low, Normal, High. High is in the accent.
struct DetailFilePriorityMenu: View {
    let name: String
    let priority: FilePriority
    let onSelect: (FilePriority) -> Void

    var body: some View {
        Menu {
            ForEach([FilePriority.skip, .low, .normal, .high], id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == priority {
                        Label(L10n.t(option.displayName), systemImage: "checkmark")
                    } else {
                        Text(L10n.t(option.displayName))
                    }
                }
            }
        } label: {
            HStack(spacing: Studio.Space.xxs) {
                Text(priority == .skip ? L10n.t("Skipped") : priority.title)
                Image(systemName: "chevron.down")
                    .studioFont(.ui, size: 8, weight: 700)
            }
            .studioFont(.caption.weight(600))
            .foregroundStyle(priority == .high ? Studio.Palette.accent : Studio.Palette.ink2)
            .padding(.horizontal, Studio.Space.s)
            .frame(minWidth: 62, minHeight: 22)
            .background(priority == .high ? Studio.Palette.accentSoft : Studio.Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(priority == .high ? Color.clear : Studio.Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Priority for %@", name))
        .accessibilityLabel(L10n.t("Priority for %@", name))
        .accessibilityValue(priority.title)
    }
}
