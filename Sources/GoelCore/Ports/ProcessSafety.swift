import Foundation

/// Guards for launching a user-configured *external tool* (antivirus, ffmpeg override, …). Those paths
/// come from the settings DB or environment — writable by any same-user process — so rules live here.
public enum ProcessSafety {

    /// Shell/script interpreters that must never be launched as a user-configured tool: accepting one
    /// turns a settings value into a `/bin/sh -c <payload>` arbitrary-code-execution bridge.
    public static let interpreterBlocklist: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh",
        "/bin/ksh", "/bin/fish", "/usr/bin/env", "/usr/bin/python", "/usr/bin/python3",
        "/usr/bin/ruby", "/usr/bin/perl", "/usr/bin/osascript", "/usr/bin/swift",
    ]

    /// A minimal `PATH`-only environment for a spawned tool, so it can't inherit
    /// sensitive variables from the app's own process.
    public static let minimalEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    /// Whether `path` is safe to launch as a user-supplied external tool: a concrete, absolute,
    /// executable file, not a known interpreter, never a bare name resolved through `$PATH`.
    public static func isSafeExecutable(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !p.isEmpty
            && p.hasPrefix("/")
            && FileManager.default.isExecutableFile(atPath: p)
            && !interpreterBlocklist.contains(p)
    }
}
