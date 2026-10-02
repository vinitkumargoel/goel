import SwiftUI
import GoelCore

extension RootView {

    func withOverlays<Content: View>(_ content: Content) -> some View {
        content
            // Clears the status bar.
            .overlay(alignment: .bottom) { ToastOverlay(queue: vm.toasts) }
            // Must stay after the toast overlay: a passing toast cannot be allowed to cover the job card.
            .overlay(alignment: .bottomTrailing) { MediaJobDock(center: vm.mediaJobs) }
            .overlay {
                if isDropTargeted || preview?.isDropTargeted == true { DropTargetOverlay() }
            }
            .overlay {
                if let request = vm.confirmRequest {
                    ConfirmDialogView(request: request) { vm.confirmRequest = nil }
                }
            }
            .overlay { AutoShutdownCountdownView(countdown: vm.autoShutdownCountdown) }
    }

    func withSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $vm.isAddSheetPresented) {
                AddDownloadSheet()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.isStatsPresented) {
                StatsView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.isLinkGrabberPresented) {
                LinkGrabberSheet()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $vm.isServerEditorPresented) {
                SFTPConnectionEditor(existing: vm.editingServer)
                    .environmentObject(vm)
            }
            .sheet(item: $vm.sftpUploadConflicts) { request in
                SFTPUploadConflictSheet(
                    request: request,
                    onResolve: { vm.resolveUploadConflicts(request, decisions: $0) },
                    onCancel: { vm.sftpUploadConflicts = nil })
            }
            .sheet(isPresented: $isCommandPalettePresented) {
                CommandPalette()
                    .environmentObject(vm)
            }
            // A snapshot never presents the first-run flow.
            .sheet(isPresented: preview == nil ? $isOnboardingPresented : .constant(false)) {
                OnboardingView()
                    .environmentObject(vm)
            }
    }
}
