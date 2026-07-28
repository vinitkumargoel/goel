import Foundation
import GoelCore

enum BrowserIntegrationService {

    /// Must match the extension's `sendNativeMessage` host name.
    static let hostName = "com.goeldownloader.host"

    /// Pinned ID from the extension manifest `key`; gates `allowed_origins`.
    static let chromeExtensionID = "cibecdmaigobbnnollnoajkiioiaepda"

    static let firefoxExtensionID = "goel@goeldownloader.app"

    private static let chromiumBrowsers: [(name: String, dir: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Arc", "Arc/User Data"),
    ]

    @discardableResult
    static func installHostManifests() -> String {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first else {
            return "Couldn’t locate Application Support"
        }
        let wrapper: URL
        do {
            wrapper = try writeWrapperScript(under: appSupport)
        } catch {
            return "Couldn’t write the helper script"
        }

        var installed: [String] = []
        for browser in chromiumBrowsers {
            let base = appSupport.appendingPathComponent(browser.dir, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }
            let manifest: [String: Any] = [
                "name": hostName,
                "description": "GoelDownloader browser capture",
                "path": wrapper.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(chromeExtensionID)/"],
            ]
            if writeManifest(manifest, in: base.appendingPathComponent("NativeMessagingHosts")) {
                installed.append(browser.name)
            }
        }

        let mozilla = appSupport.appendingPathComponent("Mozilla", isDirectory: true)
        if fm.fileExists(atPath: mozilla.path) {
            let manifest: [String: Any] = [
                "name": hostName,
                "description": "GoelDownloader browser capture",
                "path": wrapper.path,
                "type": "stdio",
                "allowed_extensions": [firefoxExtensionID],
            ]
            if writeManifest(manifest, in: mozilla.appendingPathComponent("NativeMessagingHosts")) {
                installed.append("Firefox")
            }
        }

        return installed.isEmpty
            ? "No supported browsers found"
            : "Helper installed for \(installed.joined(separator: ", "))"
    }

    /// Needed because host manifests can't pass args: browsers spawn `path` verbatim.
    private static func writeWrapperScript(under appSupport: URL) throws -> URL {
        let dir = appSupport.appendingPathComponent("GoelDownloader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("native-messaging-host.sh")
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Single-quote: double quotes would let a hostile folder name become shell code.
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = """
        #!/bin/sh
        exec \(quoted) --native-messaging-host "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private static func writeManifest(_ manifest: [String: Any], in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(hostName).json"),
                           options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static var extensionFolder: URL? {
        ResourceBundles.app?.url(forResource: "BrowserExtension", withExtension: nil)
    }
}
