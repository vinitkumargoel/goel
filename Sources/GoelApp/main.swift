import Foundation

// One binary, two roles: `--native-messaging-host` runs the stdio bridge, anything else is the GUI.
// A `main.swift` rather than `@main` so the host check runs before SwiftUI claims a window or Dock.
if CommandLine.arguments.contains("--native-messaging-host") {
    NativeMessagingHost.runLoop()
    exit(0)
}

GoelDownloaderApp.main()
