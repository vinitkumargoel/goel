import Foundation

/// `Bundle.module` is banned here — codesign bars app-root bundles, and `build_app.sh` enforces it.
public enum ResourceBundles {

    public static var core: Bundle? { bundle(named: "GoelDownloader_GoelCore") }

    public static var app: Bundle? { bundle(named: "GoelDownloader_GoelApp") }

    public static func bundle(named name: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let resolved = locate(name)
        cache[name] = resolved
        return resolved
    }

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
        // Must not be silent: keys are the English text, so a dropped bundle reads as "not localized yet".
        FileHandle.standardError.write(Data("""
            Goel°: resource bundle \(name).{\(bundleExtensions.joined(separator: ","))} \
            was not found in any of:
            \(roots.map { "  " + $0.path }.joined(separator: "\n"))
            Continuing without it — translations and bundled resources are unavailable.

            """.utf8))
        return nil
    }

    /// SwiftPM names it `.bundle` on Darwin but `.resources` on Linux; dropping either loses every translation.
    private static let bundleExtensions = ["bundle", "resources"]

    private static func searchRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if !roots.contains(standardized) { roots.append(standardized) }
        }

        let main = Bundle.main

        add(main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent())
        add(main.resourceURL)
        add(main.bundleURL)

        let own = Bundle(for: BundleToken.self)
        add(own.resourceURL)
        add(own.bundleURL)
        add(own.bundleURL.deletingLastPathComponent())

        return roots
    }
}

/// Not dead code: `Bundle(for:)` needs it to locate the bundle this code loaded from.
private final class BundleToken {}
