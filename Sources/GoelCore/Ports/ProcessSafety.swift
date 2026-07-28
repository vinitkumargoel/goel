import Foundation

/// External-tool paths come from the settings DB or environment — writable by any same-user process.
public enum ProcessSafety {

    /// Launching one of these turns a settings value into a `/bin/sh -c <payload>` code-execution bridge.
    public static let interpreterBlocklist: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh",
        "/bin/ksh", "/bin/fish", "/usr/bin/env", "/usr/bin/python", "/usr/bin/python3",
        "/usr/bin/ruby", "/usr/bin/perl", "/usr/bin/osascript", "/usr/bin/swift",
    ]

    /// `PATH`-only so a spawned tool cannot inherit sensitive variables from the app's own process.
    public static let minimalEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    /// Must be absolute and executable and not an interpreter — never a bare name resolved through `$PATH`.
    public static func isSafeExecutable(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // A directory carries the execute bit too, and `isExecutableFile` says yes to it.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return !p.isEmpty
            && p.hasPrefix("/")
            && FileManager.default.isExecutableFile(atPath: p)
            && !interpreterBlocklist.contains(p)
    }
}
