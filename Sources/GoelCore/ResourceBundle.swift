import Foundation

/// Locates the SwiftPM-generated resource bundles (`GoelDownloader_<Target>.bundle`)
/// from inside a shipped `.app`, a bare executable, or a test runner.
///
/// ## Why this exists instead of `Bundle.module`
///
/// The accessor SwiftPM generates for `Bundle.module` looks in exactly two places
/// and calls `fatalError` when neither exists:
///
///   1. `Bundle.main.bundleURL/<name>.bundle`
///   2. the absolute `.build` directory of the machine that compiled the binary
///
/// For a macOS app, `Bundle.main.bundleURL` *is* the `.app`, and resource bundles
/// cannot legally live there — `codesign` refuses to seal an app with anything
/// beside `Contents` ("unsealed contents present in the bundle root"). So in a
/// signed, distributable bundle the first path can never exist, and the app
/// survives only for as long as the *compiling* machine's `.build` directory is
/// still on disk at its original absolute path. That makes `Bundle.module` a
/// guaranteed launch crash on every end user's Mac, while looking perfectly fine
/// on the build machine — until that directory is cleaned or its git worktree is
/// deleted, at which point the developer's own installed copy starts crashing too.
///
/// This resolver searches the places a resource bundle can legitimately live and
/// returns `nil` rather than trapping, so a missing resource degrades into
/// untranslated text or a missing icon instead of killing the process.
///
/// - Important: Do not reintroduce `Bundle.module` in this package. Add a new
///   accessor below instead; `Scripts/build_app.sh` fails the build if
///   `Bundle.module` reappears in `Sources/`.
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
        // Degrading quietly is the point of this type, but degrading with NO trace at
        // all means a packaging regression that drops the bundle is indistinguishable
        // from "not localized yet" — the keys are the English text, so nothing looks
        // wrong. One line, once per name (the result is memoized), names it.
        FileHandle.standardError.write(Data("""
            Goel°: resource bundle \(name).{\(bundleExtensions.joined(separator: ","))} \
            was not found in any of:
            \(roots.map { "  " + $0.path }.joined(separator: "\n"))
            Continuing without it — translations and bundled resources are unavailable.

            """.utf8))
        return nil
    }

    /// SwiftPM names the generated bundle `<name>.bundle` on Darwin but
    /// `<name>.resources` on Linux. Only knowing the first meant the daemon silently
    /// lost every translation there, which reads as "not localized yet" because the
    /// keys ARE the English text.
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

        // When this code is loaded from something other than the main bundle —
        // an `.xctest` runner under `swift test`, or an embedded framework — the
        // bundles sit next to *that* bundle instead.
        let own = Bundle(for: BundleToken.self)
        add(own.resourceURL)
        add(own.bundleURL)
        add(own.bundleURL.deletingLastPathComponent())

        return roots
    }
}

/// Anchor class used only to locate the bundle this code was loaded from.
private final class BundleToken {}
