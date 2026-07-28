import Foundation

/// Locates SwiftPM resource bundles (`.app`, bare exe, test runner); nil where `Bundle.module` traps.
/// - Important: `Bundle.module` is banned here (codesign bars app-root bundles); `build_app.sh` enforces it.
public enum ResourceBundles {

    /// `GoelCore`'s resource bundle — the `.lproj` localization tables.
    public static var core: Bundle? { bundle(named: "GoelDownloader_GoelCore") }

    /// `GoelApp`'s resource bundle — dock/notification icons and the unpacked
    /// browser extension.
    public static var app: Bundle? { bundle(named: "GoelDownloader_GoelApp") }

    /// Resolve a resource bundle by its SwiftPM name, memoizing the answer
    /// (including a miss) so hot paths like `L10n.string` don't re-stat the disk.
    public static func bundle(named name: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let resolved = locate(name)
        cache[name] = resolved
        return resolved
    }

    // MARK: - Resolution

    private static let lock = NSLock()
    private static var cache: [String: Bundle?] = [:]

    private static func locate(_ name: String) -> Bundle? {
        let roots = searchRoots()
        for root in roots {
            for ext in bundleExtensions {
                let candidate = root.appendingPathComponent("\(name).\(ext)")
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                if let bundle = Bundle(url: candidate) { return bundle }
            }
        }
        // Degrade quietly, but not silently: keys are the English text, so a dropped bundle looks
        // identical to "not localized yet". One line, once per name (memoized), names the regression.
        FileHandle.standardError.write(Data("""
            Goel°: resource bundle \(name).{\(bundleExtensions.joined(separator: ","))} \
            was not found in any of:
            \(roots.map { "  " + $0.path }.joined(separator: "\n"))
            Continuing without it — translations and bundled resources are unavailable.

            """.utf8))
        return nil
    }

    /// SwiftPM names the bundle `<name>.bundle` on Darwin but `<name>.resources` on Linux; knowing only
    /// the first silently lost every translation in the daemon (keys ARE the English text).
    private static let bundleExtensions = ["bundle", "resources"]

    /// Directories that may hold a resource bundle, most specific first.
    private static func searchRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if !roots.contains(standardized) { roots.append(standardized) }
        }

        let main = Bundle.main

        // `Contents/MacOS` — beside the executable, where Scripts/build_app.sh
        // stages the bundles so they sit inside the signed `Contents` tree.
        add(main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent())
        // `Contents/Resources` — the conventional location, should packaging move.
        add(main.resourceURL)
        // The main bundle root: for a bare executable (`swift run`, the Linux
        // daemon) this is simply the directory the binary was launched from.
        add(main.bundleURL)

        // Loaded from something other than the main bundle (an `.xctest` runner under `swift test`,
        // an embedded framework), the bundles sit next to *that* bundle instead.
        let own = Bundle(for: BundleToken.self)
        add(own.resourceURL)
        add(own.bundleURL)
        add(own.bundleURL.deletingLastPathComponent())

        return roots
    }
}

/// Anchor class used only to locate the bundle this code was loaded from.
private final class BundleToken {}
