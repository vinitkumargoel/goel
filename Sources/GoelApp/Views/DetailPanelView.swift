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

// The five tab bodies (GeneralTab, DetailsTab, ProgressTab, FilesTab,
// ConnectionsTab), their shared rows, and the `seedCount` display helper live in
// `DetailTabs.swift`.
