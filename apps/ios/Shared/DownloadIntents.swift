import Foundation
import SwiftUI

#if canImport(AppIntents)
import AppIntents
#endif

/// Control without launching — PRD §6.5.
///
/// > "Pausing a 4 GB download from the Dynamic Island without ever opening the app is the
/// > single most demo-able thing in this product."
///
/// Every intent here sets **`openAppWhenRun = false`**. That single line is the whole feature.
/// With it `true`, tapping Pause throws the user into the app and the demo is dead; with it
/// `false`, the tap is handled out-of-process and the app stays exactly where it was.
///
/// None of these intents can touch `DownloadStore` — they may not even be running in the app's
/// process. They do two things and return:
///
/// 1. Append a record to ``CommandFile``, which the app drains on launch, on foreground and on
///    every background `URLSession` wake (`CommandDrain`).
/// 2. Rewrite ``SharedSnapshot`` optimistically, so the Live Activity flips to *Paused* on the
///    same frame as the tap rather than whenever the app next wakes.
///
/// This file is compiled into **both** targets, so it may not mention `Download`,
/// `DownloadStore` or `AppModel`. The action vocabulary is ``DownloadCommandAction``.

#if canImport(AppIntents)

// MARK: - Issuing

/// The two lines every intent runs. Kept in one place so a new intent cannot forget the
/// optimistic half and ship a button that looks broken for thirty seconds.
enum DownloadCommandDispatcher {
    static func issue(_ command: DownloadCommand, file: CommandFile = .shared) {
        file.append(command)
        OptimisticSnapshot.record(command)
    }
}

// MARK: - Per-download control

/// Pause one transfer. Backs the Live Activity's Pause button.
///
/// Conforms to `LiveActivityIntent` as well as `AppIntent`: ActivityKit only allows a
/// `Button(intent:)` inside a Live Activity to run without a foreground launch when the intent
/// declares itself Live-Activity-capable.
public struct PauseDownloadIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Pause Download" }
    public static var description: IntentDescription {
        IntentDescription("Pauses a download without opening Goel.")
    }
    /// The point of the entire task. Do not change this.
    public static var openAppWhenRun: Bool { false }
    /// Hidden from Shortcuts and Spotlight: its only parameter is a raw download `UUID`, which
    /// nobody can usefully type into a shortcut. The Live Activity resolves it by type instead.
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Download") public var downloadID: String

    public init() {}
    public init(downloadID: String) { self.downloadID = downloadID }

    public func perform() async throws -> some IntentResult {
        DownloadCommandDispatcher.issue(DownloadCommand(id: downloadID, action: .pause))
        return .result()
    }
}

/// Resume one transfer.
public struct ResumeDownloadIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Resume Download" }
    public static var description: IntentDescription {
        IntentDescription("Resumes a paused download without opening Goel.")
    }
    public static var openAppWhenRun: Bool { false }
    /// See ``PauseDownloadIntent/isDiscoverable``.
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Download") public var downloadID: String

    public init() {}
    public init(downloadID: String) { self.downloadID = downloadID }

    public func perform() async throws -> some IntentResult {
        DownloadCommandDispatcher.issue(DownloadCommand(id: downloadID, action: .resume))
        return .result()
    }
}

/// Cancel one transfer and delete its partial data. Backs the red Cancel button.
public struct CancelDownloadIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Cancel Download" }
    public static var description: IntentDescription {
        IntentDescription("Cancels a download and discards its partial data.")
    }
    public static var openAppWhenRun: Bool { false }
    /// See ``PauseDownloadIntent/isDiscoverable``.
    public static var isDiscoverable: Bool { false }

    @Parameter(title: "Download") public var downloadID: String

    public init() {}
    public init(downloadID: String) { self.downloadID = downloadID }

    public func perform() async throws -> some IntentResult {
        DownloadCommandDispatcher.issue(DownloadCommand(id: downloadID, action: .cancel))
        return .result()
    }
}

// MARK: - Queue-wide

/// Pause everything. The Siri phrase and the aggregate Live Activity both land here.
public struct PauseAllIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Pause All Downloads" }
    public static var description: IntentDescription {
        IntentDescription("Pauses every active download without opening Goel.")
    }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult {
        DownloadCommandDispatcher.issue(DownloadCommand(id: DownloadCommand.allID, action: .pauseAll))
        return .result()
    }
}

// MARK: - Shortcuts / Siri

/// Queue a URL from Shortcuts, a share sheet automation or Siri, without a foreground launch.
///
/// The snapshot is deliberately *not* updated optimistically here: the widget has no id, no
/// filename and no size for a download that does not exist yet, and inventing a row would put
/// a phantom entry in the Live Activity. The app materialises it on the next drain.
public struct AddDownloadIntent: AppIntent {
    public static var title: LocalizedStringResource { "Add Download" }
    public static var description: IntentDescription {
        IntentDescription("Queues a URL in Goel without opening the app.")
    }
    public static var openAppWhenRun: Bool { false }

    @Parameter(title: "URL") public var url: URL

    public init() {}
    public init(url: URL) { self.url = url }

    public static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$url) with Goel")
    }

    public func perform() async throws -> some IntentResult {
        DownloadCommandDispatcher.issue(
            DownloadCommand(id: UUID().uuidString, action: .add, payload: url.absoluteString)
        )
        return .result()
    }
}

// MARK: - Live Activity button

/// The button behind ``LiveActivityActionButtons``.
///
/// It exists because `Button(intent:)` is generic over a *concrete* `AppIntent` type — there is
/// no `Button(intent: any AppIntent)` — so the choice of intent has to be made in a `switch`
/// somewhere. Making it here keeps `Shared/WidgetViews.swift` to a one-expression change and
/// keeps App Intents knowledge in the App Intents file.
public struct DownloadIntentButton<Label: View>: View {
    public var action: DownloadCommandAction
    public var downloadID: String
    public var accessibilityLabel: String
    public var label: () -> Label

    public init(
        action: DownloadCommandAction,
        downloadID: String,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.downloadID = downloadID
        self.accessibilityLabel = accessibilityLabel
        self.label = label
    }

    public var body: some View {
        Group {
            switch action {
            case .resume:
                Button(intent: ResumeDownloadIntent(downloadID: downloadID), label: label)
            case .cancel:
                Button(intent: CancelDownloadIntent(downloadID: downloadID), label: label)
            case .pauseAll:
                Button(intent: PauseAllIntent(), label: label)
            case .pause, .add:
                Button(intent: PauseDownloadIntent(downloadID: downloadID), label: label)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

#else

/// AppIntents is unavailable on this platform — draw the label, do nothing. The app is iOS 18
/// only, so this branch never ships; it exists so `WidgetViews` stays compilable in isolation.
public struct DownloadIntentButton<Label: View>: View {
    public var action: DownloadCommandAction
    public var downloadID: String
    public var accessibilityLabel: String
    public var label: () -> Label

    public init(
        action: DownloadCommandAction,
        downloadID: String,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.downloadID = downloadID
        self.accessibilityLabel = accessibilityLabel
        self.label = label
    }

    public var body: some View { label() }
}

#endif
