import Foundation
import GoelCore

enum UpdateChecker {

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(version: String, url: URL)
        case notConfigured
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
    }

    /// Unattended, so it must go through ``NetworkGuard`` with the user's proxy — never `URLSession.shared`.
    static func check(feedURL: String,
                      proxy: NetworkGuard.ProxySpec = NetworkGuard.ProxySpec(),
                      userAgent: String = "GoelDownloader/1.0 (macOS)") async -> Outcome {
        // HTTPS only: the feed picks the page the user is offered, so plaintext hands that to the network.
        let trimmed = feedURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https" else {
            return .notConfigured
        }
        guard let data = await NetworkGuard.fetch(url: url, proxy: proxy,
                                                  userAgent: userAgent) else {
            return .failed(L10n.t("Couldn’t reach the update feed."))
        }
        guard let release = Self.decodeRelease(data) else {
            return .failed(L10n.t("The update feed didn’t contain a release."))
        }
        let latest = release.version.hasPrefix("v")
            ? String(release.version.dropFirst()) : release.version
        // Keep these cases apart: folded together, a newer release with a bad link reads as "Up to date".
        guard let candidate = components(latest) else {
            return .failed(L10n.t("The update feed gave a version this app can’t read."))
        }
        guard let running = components(currentVersion),
              isNewer(candidate, than: running) else {
            return .upToDate(current: currentVersion)
        }
        // Opened with NSWorkspace: never accept a scheme that could launch something local (file:).
        guard let page = URL(string: release.page),
              page.scheme?.lowercased() == "https" else {
            return .failed(L10n.t("Version %@ is available, but the update feed gave an unusable link.",
                                  latest))
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
        if let one = try? JSONDecoder().decode(Release.self, from: data) { return one }
        return (try? JSONDecoder().decode([Release].self, from: data))?.first
    }

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

    /// Not `Int($0) ?? 0`: that parsed 1.0.3-rc1 as [1,0,0], i.e. not newer.
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
