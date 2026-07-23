import Foundation
import OSLog

#if canImport(AppIntents)
import AppIntents
#endif

/// The app half of the App Intents story (T15).
///
/// An intent tapped in the Dynamic Island can only write a record — see ``CommandFile``. This
/// is where those records become real work: the engine actually stops sending bytes, the store
/// actually shows *Paused*, and the file is emptied so nothing is applied twice.
///
/// Drain from three places, all of them cheap:
///
/// | When | Why |
/// |---|---|
/// | Launch | the app was killed between the tap and now |
/// | Foreground | the common case — user taps, then opens the app |
/// | Background `URLSession` wake | the demo case — the tap must stop the transfer while the app is still in the background |
@MainActor
public enum CommandDrain {

    private static let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "CommandDrain")

    /// Applies every pending command, truncates the file, and returns what it applied.
    ///
    /// Safe to call as often as you like: ``CommandFile/drain(now:)`` is idempotent, and an
    /// empty drain costs one file read.
    @discardableResult
    public static func drain(into app: AppModel, now: Date = Date()) -> [DownloadCommand] {
        drain(into: app, from: .shared, now: now)
    }

    /// Testable form — tests inject a `CommandFile` rooted in a temporary directory so they
    /// never read or write the real App Group container.
    @discardableResult
    public static func drain(into app: AppModel, from file: CommandFile, now: Date = Date()) -> [DownloadCommand] {
        let commands = file.drain(now: now)
        guard !commands.isEmpty else { return [] }

        for command in commands {
            apply(command, to: app)
        }

        // The intent already wrote an optimistic snapshot. Overwrite it with the truth now that
        // the real store has moved, rather than waiting out the persist debounce, and refresh
        // the Live Activity so the button the user pressed agrees with the queue.
        app.store.persistNow()
        ActivityController.shared.sync(app.store.downloads)

        log.info("Drained \(commands.count, privacy: .public) command(s) from the App Group.")
        return commands
    }

    // MARK: - Application

    /// Every branch is a guarded no-op when it does not apply. A command naming a download that
    /// finished, failed or was deleted while the app was suspended is normal, not an error —
    /// the user tapped against a snapshot that has since moved on.
    private static func apply(_ command: DownloadCommand, to app: AppModel) {
        switch command.action {
        case .pause:
            guard let id = UUID(uuidString: command.id), let d = app.store[id] else { return }
            // `togglePause` toggles; calling it on something already paused would resume it.
            guard d.status != .paused, !d.status.isTerminal, d.status != .verifying else { return }
            app.togglePause(id)

        case .resume:
            guard let id = UUID(uuidString: command.id), let d = app.store[id] else { return }
            guard d.status == .paused || d.status == .failed else { return }
            app.togglePause(id)

        case .cancel:
            guard let id = UUID(uuidString: command.id), app.store[id] != nil else { return }
            app.remove(id)

        case .pauseAll:
            for d in app.store.downloads
            where !d.status.isTerminal && d.status != .paused && d.status != .verifying {
                app.togglePause(d.id)
            }

        case .add:
            guard let raw = command.payload,
                  let url = URL(string: raw),
                  url.scheme != nil, url.host != nil
            else {
                log.warning("Discarding an add command with no usable URL.")
                return
            }
            app.start(
                Download(
                    url: url,
                    filename: AddSheet.filename(from: url),
                    saveDirectory: AddSheet.rootFolder,
                    kind: .infer(from: url),
                    status: .queued
                )
            )
        }
    }
}

// MARK: - Shortcuts / Siri

#if canImport(AppIntents)

/// Siri and Spotlight phrases.
///
/// **This lives in the app target on purpose.** `Shared/DownloadIntents.swift` is compiled into
/// both the app *and* the widget extension, and an `AppShortcutsProvider` in two bundles is a
/// duplicate registration — the system reads app shortcuts out of the app bundle's metadata,
/// so a second copy in the extension is at best ignored and at worst shadows the real one.
/// `CommandDrain.swift` is the app-only file this task owns, so it is the provider's home.
///
/// Only ``PauseAllIntent`` gets phrases: it is the one action that needs no parameter, so Siri
/// can run it with nothing but the sentence. ``AddDownloadIntent``, ``PauseDownloadIntent`` and
/// the rest still appear as actions in the Shortcuts app automatically — every `AppIntent` does.
public struct GoelAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseAllIntent(),
            phrases: [
                "Pause downloads in \(.applicationName)",
                "Pause all downloads in \(.applicationName)",
                "Stop downloading in \(.applicationName)"
            ],
            shortTitle: "Pause Downloads",
            systemImageName: "pause.circle"
        )
    }
}

#endif
