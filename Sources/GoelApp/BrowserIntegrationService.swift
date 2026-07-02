import Foundation

/// Installs the native-messaging plumbing the browser extension needs:
/// a wrapper script that relaunches this binary in host mode, plus a host
/// manifest in every installed browser's `NativeMessagingHosts` directory.
/// Everything lands under the user's home — no privileges, fully reversible.
enum BrowserIntegrationService {

    /// Must match the extension's `sendNativeMessage` host name.
    static let hostName = "com.goeldownloader.host"

    /// The unpacked extension's pinned Chrome ID (derived from the `key` in
    /// its manifest.json, so it is stable wherever it's loaded from).
    static let chromeExtensionID = "cibecdmaigobbnnollnoajkiioiaepda"

    /// The Firefox add-on id from the extension manifest's gecko settings.
    static let firefoxExtensionID = "goel@goeldownloader.app"

    /// Chromium-family browsers: App Support subdirectory of each.
    private static let chromiumBrowsers: [(name: String, dir: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Arc", "Arc/User Data"),
    ]

    /// Write the wrapper + manifests for every browser found. Returns a
    /// human-readable summary for the settings pane toast.
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

    /// The wrapper exists because host manifests can't pass arguments: browsers
    /// spawn exactly `path`, so the script re-adds the host-mode flag. It also
    /// survives the app moving (reinstall refreshes the embedded path).
    private static func writeWrapperScript(under appSupport: URL) throws -> URL {
        let dir = appSupport.appendingPathComponent("GoelDownloader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("native-messaging-host.sh")
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // Single-quote the path (with the standard '\'' escape for embedded
        // quotes): double quotes would still evaluate `$(…)`/backticks, so an
        // app living under a hostile-looking folder name must not become
        // shell code every time a browser spawns the host.
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

    /// Where the unpacked extension lives (inside the app bundle's resources),
    /// for the "reveal" button and the load-unpacked instructions.
    static var extensionFolder: URL? {
        Bundle.module.url(forResource: "BrowserExtension", withExtension: nil)
    }
}
