import Foundation

// `main.swift`, not `@main`: the host check must run before SwiftUI claims a window or Dock.
if CommandLine.arguments.contains("--native-messaging-host") {
    NativeMessagingHost.runLoop()
    exit(0)
}

GoelDownloaderApp.main()
