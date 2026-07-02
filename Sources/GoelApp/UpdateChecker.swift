import Foundation

/// A lightweight release checker for the direct-distribution build: fetches a
/// GitHub-style releases feed (`tag_name` + `html_url`), compares against the
/// bundle version, and reports whether something newer shipped. Full Sparkle
/// integration can replace this once an appcast is hosted; the menu item and
/// setting stay the same.
enum UpdateChecker {

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(version: String, url: URL)
        case notConfigured
        case failed(String)
    }

    /// The running app's version (packaged builds carry it in Info.plist).
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static func check(feedURL: String) async -> Outcome {
        // HTTPS only: the feed decides which page the user is offered to open,
        // so a tamperable plaintext feed would hand that choice to the network.
        let trimmed = feedURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https" else {
            return .notConfigured
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let release = Self.decodeRelease(data) else {
                return .failed("The update feed didn’t contain a release.")
            }
            let latest = release.version.hasPrefix("v")
                ? String(release.version.dropFirst()) : release.version
            // The page is opened with NSWorkspace — never accept a scheme that
            // could launch something local (file:) or otherwise non-web.
            if isNewer(latest, than: currentVersion),
               let page = URL(string: release.page),
               page.scheme?.lowercased() == "https" {
                return .available(version: latest, url: page)
            }
            return .upToDate(current: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
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

    /// Numeric dotted-component comparison ("1.10" > "1.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
