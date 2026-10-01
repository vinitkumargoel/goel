import Foundation
import GoelCore
#if canImport(Darwin)
import Darwin
#endif

/// What Settings › Browser shows per browser: is it installed, is the helper manifest in place
/// and pointing at this app, has the extension talked to us, and when it last captured.
struct BrowserStatus: Identifiable, Equatable {
    enum Helper: Equatable { case installed, missing, stale }

    let name: String
    let helper: Helper
    var lastSeen: Date?
    var lastCapture: Date?

    var id: String { name }
}

/// Written by the native-messaging host process (a separate launch of this binary, spawned by
/// the browser) and read by the app. A small 0600 JSON file: browser name → timestamps.
enum BrowserActivityLog {

    struct Entry: Codable, Equatable {
        var lastSeen: Date?
        var lastCapture: Date?
    }

    enum Event { case seen, capture }

    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GoelDownloader/browser-activity.json")
    }

    static func read(from url: URL? = fileURL) -> [String: Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Best effort: a failed write only means the card shows "never" for a while.
    static func record(_ event: Event, browser: String, at date: Date = Date(), to url: URL? = fileURL) {
        guard let url else { return }
        var all = read(from: url)
        var entry = all[browser] ?? Entry()
        entry.lastSeen = date
        if event == .capture { entry.lastCapture = date }
        all[browser] = entry
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Names the browser from the executable that spawned the host ("…/Brave Browser.app/…").
    static func browserName(fromExecutablePath path: String) -> String {
        let lower = path.lowercased()
        let table: [(needle: String, name: String)] = [
            ("brave", "Brave"), ("microsoft edge", "Edge"), ("vivaldi", "Vivaldi"),
            ("/arc.app", "Arc"), ("chromium", "Chromium"), ("google chrome", "Chrome"),
            ("firefox", "Firefox"), ("safari", "Safari"),
        ]
        return table.first { lower.contains($0.needle) }?.name ?? L10n.t("Browser")
    }

    /// The parent process's executable: the browser, since it launches the host directly.
    static func parentExecutablePath() -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }

    static var currentBrowser: String {
        parentExecutablePath().map(browserName(fromExecutablePath:)) ?? L10n.t("Browser")
    }
}

extension BrowserIntegrationService {

    /// Per-browser status for every supported browser whose profile folder exists.
    static func statuses(activity: [String: BrowserActivityLog.Entry] = BrowserActivityLog.read()) -> [BrowserStatus] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let wrapper = currentWrapperIsFresh(under: appSupport)
        var out: [BrowserStatus] = []
        for browser in helperLocations(appSupport) where fm.fileExists(atPath: browser.base.path) {
            let manifest = browser.base.appendingPathComponent("NativeMessagingHosts/\(hostName).json")
            let helper: BrowserStatus.Helper = !fm.fileExists(atPath: manifest.path) ? .missing
                : (wrapper ? .installed : .stale)
            let entry = activity[browser.name]
            out.append(BrowserStatus(name: browser.name, helper: helper,
                                     lastSeen: entry?.lastSeen, lastCapture: entry?.lastCapture))
        }
        return out
    }

    /// The wrapper script must still `exec` this very binary, or a moved app breaks capture.
    private static func currentWrapperIsFresh(under appSupport: URL) -> Bool {
        let script = appSupport.appendingPathComponent("GoelDownloader/native-messaging-host.sh")
        guard let body = try? String(contentsOf: script, encoding: .utf8) else { return false }
        guard let binary = Bundle.main.executablePath else { return true }
        return body.contains(binary)
    }

    private static func helperLocations(_ appSupport: URL) -> [(name: String, base: URL)] {
        let chromium: [(String, String)] = [
            ("Chrome", "Google/Chrome"), ("Chromium", "Chromium"), ("Brave", "BraveSoftware/Brave-Browser"),
            ("Edge", "Microsoft Edge"), ("Vivaldi", "Vivaldi"), ("Arc", "Arc/User Data"),
        ]
        var out = chromium.map { (name: $0.0, base: appSupport.appendingPathComponent($0.1, isDirectory: true)) }
        out.append((name: "Firefox", base: appSupport.appendingPathComponent("Mozilla", isDirectory: true)))
        return out
    }
}
