import Foundation
import GoelCore

/// A lightweight release checker for the direct-distribution build: fetches a GitHub-style feed,
/// compares against the bundle version, and reports whether something newer shipped.
enum UpdateChecker {

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(version: String, url: URL)
        case notConfigured
        case failed(String)
    }

    /// The running app's version (packaged builds carry it in Info.plist).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
    }

    /// Fetch the feed and decide whether a newer release exists. `proxy`/`userAgent` must be the
    /// *user's*: this runs with nobody in the loop, so it goes through ``NetworkGuard``, not `URLSession.shared`.
    static func check(feedURL: String,
                      proxy: NetworkGuard.ProxySpec = NetworkGuard.ProxySpec(),
                      userAgent: String = "GoelDownloader/1.0 (macOS)") async -> Outcome {
        // HTTPS only: the feed decides which page the user is offered to open,
        // so a tamperable plaintext feed would hand that choice to the network.
        let trimmed = feedURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https" else {
            return .notConfigured
        }
        // The guard collapses every failure (transport error, non-2xx, refused target) into nil, so
        // there is no per-error string left to surface — one plain-language message covers them all.
        guard let data = await NetworkGuard.fetch(url: url, proxy: proxy,
                                                  userAgent: userAgent) else {
            return .failed("Couldn’t reach the update feed.")
        }
        guard let release = Self.decodeRelease(data) else {
            return .failed("The update feed didn’t contain a release.")
        }
        let latest = release.version.hasPrefix("v")
            ? String(release.version.dropFirst()) : release.version
        // Each of these is reported for what it is. Folding them together meant a real, newer release
        // with an unusable link came out as "Up to date" — a failure reported as success.
        guard let candidate = components(latest) else {
            return .failed("The update feed gave a version this app can’t read.")
        }
        guard let running = components(currentVersion),
              isNewer(candidate, than: running) else {
            return .upToDate(current: currentVersion)
        }
        // The page is opened with NSWorkspace — never accept a scheme that
        // could launch something local (file:) or otherwise non-web.
        guard let page = URL(string: release.page),
              page.scheme?.lowercased() == "https" else {
            return .failed("Version \(latest) is available, but the update feed gave an unusable link.")
        }
        return .available(version: latest, url: page)
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        var version: String { tag_name }
        var page: String { html_url }
    }

    private static func decodeRelease(_ data: Data) -> Release? {
        // Accept both a single release object and a release array (newest first).
        if let one = try? JSONDecoder().decode(Release.self, from: data) { return one }
        return (try? JSONDecoder().decode([Release].self, from: data))?.first
    }

    /// Numeric dotted-component comparison ("1.10" > "1.9"). An unparseable version is not newer —
    /// but ``check(feedURL:)`` asks ``components(_:)`` itself so it can say the feed was unreadable.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        return isNewer(a, than: b)
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A dotted version as numeric components, or nil when a component has no leading number. The
    /// pre-release suffix forces this: `Int($0) ?? 0` made 1.0.3-rc1 parse as [1,0,0], i.e. not newer.
    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { return nil }
            out.append(value)
        }
        return out
    }
}
