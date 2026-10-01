import SwiftUI
import AppKit
import GoelCore

/// Open With ▸: the default app first, then the others that claim the file, then Other….
struct OpenWithMenu: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Menu(L10n.t("Open With")) {
            let apps = OpenWithCache.applications(forFile: task.primaryFilePath)
            ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                Button(index == 0 ? L10n.t("%@ (default)", OpenWithCache.name(of: app)) : OpenWithCache.name(of: app)) {
                    vm.open(task, withApplicationAt: app)
                }
            }
            if !apps.isEmpty { Divider() }
            Button(L10n.t("Other…")) { vm.openWithOtherApp(task) }
        }
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

/// Share…: the system share picker, opened once the context menu has closed.
struct ShareMenuItem: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Button(L10n.t("Share…")) {
            DispatchQueue.main.async { vm.share(task, from: nil) }
        }
    }
}

/// When Done ▸ for a download that hasn't finished yet.
struct WhenDoneMenu: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        Menu(L10n.t("When Done")) {
            ForEach(WhenDone.Kind.allCases) { kind in
                Toggle(WhenDonePicker.label(kind), isOn: Binding(
                    get: { (task.whenDone?.kind ?? .nothing) == kind },
                    set: { on in if on { choose(kind) } }))
            }
        }
    }

    private func choose(_ kind: WhenDone.Kind) {
        switch kind {
        case .nothing: vm.setWhenDone(nil, task: task.id)
        case .open, .reveal: vm.setWhenDone(WhenDone(kind), task: task.id)
        case .openWith, .moveTo, .runScript:
            let id = task.id
            DispatchQueue.main.async {
                guard let target = AppViewModel.chooseWhenDoneTarget(for: kind) else { return }
                vm.setWhenDone(WhenDone(kind, target: target), task: id)
            }
        }
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
