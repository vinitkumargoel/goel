import Foundation

// `main.swift`, not `@main`: the host check must run before SwiftUI claims a window or Dock.
if CommandLine.arguments.contains("--native-messaging-host") {
    NativeMessagingHost.runLoop()
    exit(0)
}

// Before any view is built: Studio text resolves its typefaces from this registration and falls
// back to the system font for any family that fails to register.
StudioFonts.registerAll()

#if DEBUG
// `GoelDownloader --studio-snapshots <outdir> [--only <prefix>]`: renders the registered Studio
// views to PNGs in light and dark, then exits. Never starts the engine or opens the database.
if let code = MainActor.assumeIsolated({ StudioSnapshotCommand.runIfRequested(CommandLine.arguments) }) {
    exit(code)
}
#endif

GoelDownloaderApp.main()
