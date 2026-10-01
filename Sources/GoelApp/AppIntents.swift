import AppIntents
import Foundation
import GoelCore

/// Shortcuts / Siri / Spotlight actions. Each runs in the app (it opens if needed), through the
/// same view-model calls the menus use, so an intent can do nothing the UI can't.
enum IntentBridge {
    /// The window's model appears a moment after launch; an intent that woke the app waits for it.
    @MainActor
    static func viewModel() async throws -> AppViewModel {
        for _ in 0..<50 {
            if let vm = AppViewModel.shared { return vm }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentError.notReady
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case notReady
        case invalidURL
        case unknownProfile(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notReady: return "Goel° didn’t finish opening. Try again."
            case .invalidURL: return "That isn’t a link Goel° can download."
            case .unknownProfile(let name): return "There’s no traffic profile named \(name)."
            }
        }
    }
}

struct AddDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Download"
    static let description = IntentDescription("Queues a link (http, magnet, stream) in Goel°.")
    static let openAppWhenRun = true

    @Parameter(title: "URL")
    var url: URL

    /// Content-type filtering needs macOS 15; a file here is ignored in favour of its folder.
    @Parameter(title: "Folder")
    var folder: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$url) to \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let vm = try await IntentBridge.viewModel()
        guard InboundAdd.parseSources(from: url.absoluteString).first != nil else {
            throw IntentBridge.IntentError.invalidURL
        }
        vm.add(rawLines: url.absoluteString, saveDirectory: Self.directory(folder?.fileURL), priority: .normal)
        return .result()
    }

    static func directory(_ url: URL?) -> String? {
        guard let url else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDir ? url.path : url.deletingLastPathComponent().path
    }
}

struct PauseAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause All Downloads"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.viewModel().pauseAll()
        return .result()
    }
}

struct ResumeAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume All Downloads"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.viewModel().resumeAll()
        return .result()
    }
}

struct TrafficProfileOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        try await IntentBridge.viewModel().settings.profiles.map(\.name)
    }
}

struct SetTrafficProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Traffic Profile"
    static let openAppWhenRun = true

    @Parameter(title: "Profile", optionsProvider: TrafficProfileOptions())
    var profile: String

    static var parameterSummary: some ParameterSummary {
        Summary("Switch Goel° to \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let vm = try await IntentBridge.viewModel()
        guard vm.settings.profiles.contains(where: { $0.name == profile }) else {
            throw IntentBridge.IntentError.unknownProfile(profile)
        }
        vm.setProfile(profile)
        return .result()
    }
}

struct GetActiveDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Active Downloads"
    static let description = IntentDescription("Names and progress of what is downloading now.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let vm = try await IntentBridge.viewModel()
        let lines = IntentSummaries.activeLines(vm.tasks)
        return .result(value: lines)
    }
}

/// Plain-text lines for Shortcuts, kept out of the intent so they can be tested.
enum IntentSummaries {
    static func activeLines(_ tasks: [DownloadTask]) -> [String] {
        tasks.filter { $0.status.isActive }.map { task in
            let percent = Int((task.fractionCompleted * 100).rounded())
            return "\(task.name) — \(percent)%"
        }
    }
}

struct GoelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddDownloadIntent(), phrases: ["Add a download to \(.applicationName)"],
                    shortTitle: "Add Download", systemImageName: "plus.circle")
        AppShortcut(intent: PauseAllIntent(), phrases: ["Pause \(.applicationName) downloads"],
                    shortTitle: "Pause All", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAllIntent(), phrases: ["Resume \(.applicationName) downloads"],
                    shortTitle: "Resume All", systemImageName: "play.circle")
        AppShortcut(intent: SetTrafficProfileIntent(), phrases: ["Set \(.applicationName) traffic profile"],
                    shortTitle: "Traffic Profile", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: GetActiveDownloadsIntent(), phrases: ["What is \(.applicationName) downloading"],
                    shortTitle: "Active Downloads", systemImageName: "arrow.down.circle")
    }
}
