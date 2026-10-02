import SwiftUI
import AppKit
import GoelCore

/// The file submenus a finished or running download offers, as menu nodes. The row context
/// menu and the views below (kept for the Detail hero's "…" button) draw the same nodes.
@MainActor
enum FileActionNodes {

    /// Open With ▸: the default app first, then the others that claim the file, then Other….
    static func openWith(_ task: DownloadTask, vm: AppViewModel) -> DownloadMenuNode {
        let apps = OpenWithCache.applications(forFile: task.primaryFilePath)
        var items: [DownloadMenuNode] = apps.enumerated().map { index, app in
            let name = OpenWithCache.name(of: app)
            return .button(index == 0 ? L10n.t("%@ (default)", name) : name) { vm.open(task, withApplicationAt: app) }
        }
        if !apps.isEmpty { items.append(.divider) }
        items.append(.button(L10n.t("Other…")) { vm.openWithOtherApp(task) })
        return .submenu(L10n.t("Open With"), symbol: "arrow.up.forward.app", items)
    }

    /// Share…: the system share picker, opened once the context menu has closed.
    static func share(_ task: DownloadTask, vm: AppViewModel) -> DownloadMenuNode {
        .button(L10n.t("Share…"), symbol: "square.and.arrow.up") {
            DispatchQueue.main.async { vm.share(task, from: nil) }
        }
    }

    /// When Done ▸ for a download that hasn't finished yet.
    static func whenDone(_ task: DownloadTask, vm: AppViewModel) -> DownloadMenuNode {
        let current = task.whenDone?.kind ?? .nothing
        let id = task.id
        let items: [DownloadMenuNode] = WhenDone.Kind.allCases.map { kind in
            .choice(WhenDonePicker.label(kind), isOn: current == kind) {
                switch kind {
                case .nothing: vm.setWhenDone(nil, task: id)
                case .open, .reveal: vm.setWhenDone(WhenDone(kind), task: id)
                case .openWith, .moveTo, .runScript:
                    DispatchQueue.main.async {
                        guard let target = AppViewModel.chooseWhenDoneTarget(for: kind) else { return }
                        vm.setWhenDone(WhenDone(kind, target: target), task: id)
                    }
                }
            }
        }
        return .submenu(L10n.t("When Done"), symbol: "flag.checkered", items)
    }
}

/// Launch Services lookups are slow enough to notice on a long list; the answer only changes
/// when apps are installed, so it's kept per file extension for the session.
@MainActor
enum OpenWithCache {
    private static var byExtension: [String: [URL]] = [:]
    static let limit = 12

    static func applications(forFile path: String) -> [URL] {
        let ext = (path as NSString).pathExtension.lowercased()
        if let cached = byExtension[ext] { return cached }
        let apps = Array(AppViewModel.applications(forFile: path).prefix(limit))
        // An extensionless file tells us nothing about the next one.
        if !ext.isEmpty { byExtension[ext] = apps }
        return apps
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Open With ▸ as a menu item view.
struct OpenWithMenu: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        DownloadMenuContent(nodes: [FileActionNodes.openWith(task, vm: vm)])
    }
}

/// Share… as a menu item view.
struct ShareMenuItem: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        DownloadMenuContent(nodes: [FileActionNodes.share(task, vm: vm)])
    }
}

/// When Done ▸ as a menu item view.
struct WhenDoneMenu: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        DownloadMenuContent(nodes: [FileActionNodes.whenDone(task, vm: vm)])
    }
}

/// The hero's "…" button: Open With and Share, which don't earn a pill of their own.
struct CompletedHeroMoreMenu: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Menu {
            OpenWithMenu(task: task, vm: vm)
            ShareMenuItem(task: task, vm: vm)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("More actions"))
        .accessibilityLabel(L10n.t("More actions for %@", task.name))
    }
}

/// Convert To / Extract Audio. Observes ``MediaJobCenter`` directly: a nested observable's
/// changes don't propagate through the outer one.
struct MediaMenuItems: View {
    let task: DownloadTask
    let vm: AppViewModel
    @ObservedObject var center: MediaJobCenter

    var body: some View {
        DownloadMenuContent(nodes: MediaMenuNodes.make(task: task, vm: vm, center: center))
    }
}

@MainActor
enum MediaMenuNodes {

    static func make(task: DownloadTask, vm: AppViewModel, center: MediaJobCenter) -> [DownloadMenuNode] {
        if let reason = vm.ffmpegUnavailableReason {
            return [
                .button(L10n.t("Convert To…"), symbol: "arrow.left.arrow.right") { vm.toastNow(reason, kind: .info) },
                .button(L10n.t("Extract Audio…"), symbol: "waveform") { vm.toastNow(reason, kind: .info) },
            ]
        }
        let input = URL(fileURLWithPath: task.savePath)
        let live = center.liveJobs(input: input)
        var nodes: [DownloadMenuNode] = live.map { job in
            .button(L10n.t("Cancel %@", L10n.midSentence(job.kind.activeTitle))) { center.cancel(job.id) }
        }
        if !live.isEmpty { nodes.append(.divider) }
        nodes.append(.submenu(L10n.t("Convert To"), symbol: "arrow.left.arrow.right",
                              MediaContainer.convertTargets.map { ext in
            .button(label(for: ext, source: input.pathExtension),
                    isEnabled: center.liveJob(input: input, outputExtension: ext) == nil) {
                vm.convertFile(task: task, toExtension: ext)
            }
        }))
        nodes.append(.submenu(L10n.t("Extract Audio"), symbol: "waveform",
                              AudioExtractionFormat.allCases.map { format in
            .button(format.displayName,
                    isEnabled: center.liveJob(input: input, outputExtension: format.rawValue) == nil) {
                vm.extractAudio(task: task, format: format)
            }
        }))
        return nodes
    }

    static func label(for ext: String, source: String) -> String {
        guard !source.isEmpty, MediaContainer.likelyStreamCopy(from: source, to: ext) else {
            return ext.uppercased()
        }
        return L10n.t("%@ — copy, instant", ext.uppercased())
    }
}
