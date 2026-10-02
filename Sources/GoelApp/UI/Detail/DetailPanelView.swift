import SwiftUI
import GoelCore

/// The inspector's content for the right-hand floating sheet: the selected download, several
/// downloads, or the queue overview when nothing is selected. MainWindow draws the sheet's
/// surface, rim and shadow around it; this view draws no outer chrome.
struct DetailPanelView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        Group {
            if vm.selectedTasks.count > 1 {
                MultiSelectionPanel()
            } else if let task = vm.selectedTask {
                DetailTaskSheet(task: task)
            } else {
                QueueOverviewPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Studio.Palette.ink)
    }
}

/// One download: head, tabs, the scrolling tab body and the action bar pinned at the foot.
struct DetailTaskSheet: View {
    let task: DownloadTask
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(task: task)
                .padding(.horizontal, Studio.Space.l)
                .padding(.top, Studio.Space.l)
                .padding(.bottom, Studio.Space.m)
            DetailTabSwitcher(selection: $vm.detailTab, tabs: DetailTab.available(for: task))
                .padding(.horizontal, Studio.Space.l)
                .padding(.bottom, Studio.Space.m)
            ScrollView {
                DetailTabBody(task: task, tab: vm.detailTab.resolved(for: task))
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.top, 2)
                    .padding(.bottom, Studio.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DetailActionBar(task: task)
        }
    }
}

/// The body of one tab, shared by the side sheet and the bottom dock.
struct DetailTabBody: View {
    let task: DownloadTask
    let tab: DetailTab

    var body: some View {
        switch tab {
        case .overview: DetailOverviewTab(task: task)
        case .files: DetailFilesTab(task: task)
        case .network: DetailNetworkTab(task: task)
        }
    }
}
