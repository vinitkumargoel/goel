import SwiftUI
import GoelCore

/// The whole window: a top toolbar, a sidebar | list | detail body, and a bottom
/// status bar — matching the layout in `visual.html`.
struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            AppToolbar()
            Divider()
            if let warning = vm.persistenceWarning {
                persistenceBanner(warning)
                Divider()
            }
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                Divider()
                DownloadListView()
                    .frame(minWidth: 420)
                if vm.detailPanelVisible {
                    Divider()
                    DetailPanelView()
                        .frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: vm.detailPanelVisible)
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 1040, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { toastView }
        .sheet(isPresented: $vm.isAddSheetPresented) {
            AddDownloadSheet()
                .environmentObject(vm)
        }
    }

    private func persistenceBanner(_ warning: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(warning).font(.system(size: 12))
            Spacer()
            Button {
                vm.persistenceWarning = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = vm.toast {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(toast).font(.system(size: 12.5))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
            .shadow(radius: 12, y: 6)
            .padding(.bottom, 52)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
