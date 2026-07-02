import Foundation

// The one binary serves two roles. Browsers spawn it (through the wrapper
// script the settings pane installs) with `--native-messaging-host` to run the
// stdio extension bridge; every other launch is the normal GUI app.
//
// This is a `main.swift` rather than `@main` because the host check must run
// before SwiftUI initializes anything — a native-messaging invocation must
// never flash a window or claim the Dock.
if CommandLine.arguments.contains("--native-messaging-host") {
    NativeMessagingHost.runLoop()
    exit(0)
}

GoelDownloaderApp.main()
