import Foundation

/// Result of running an external command.
struct Ran {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

/// Thin `Process` wrapper. Everything this CLI does to the init system goes through
/// `systemctl`/`journalctl` rather than D-Bus, because that is what an operator can verify by hand.
enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    passthrough: Bool = false) -> Ran {
        guard let path = which(executable) else {
            return Ran(status: 127, out: "", err: "\(executable) not found on PATH")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        if !passthrough {
            process.standardOutput = outPipe
            process.standardError = errPipe
        }
        do {
            try process.run()
        } catch {
            return Ran(status: 127, out: "", err: "\(executable): \(error)")
        }
        // Read before waiting: a command that fills the 64 KiB pipe buffer would
        // otherwise block forever while we wait for it to exit.
        var outData = Data(), errData = Data()
        if !passthrough {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        return Ran(status: process.terminationStatus,
                   out: String(data: outData, encoding: .utf8) ?? "",
                   err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Absolute paths only — resolving a bare name through `PATH` would let a
    /// caller's environment decide which `systemctl` a root command runs.
    static func which(_ executable: String) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"] {
            let candidate = directory + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// systemd operations on the `goel` unit.
enum Service {
    static var systemdAvailable: Bool {
        Shell.which("systemctl") != nil && FileManager.default.fileExists(atPath: "/run/systemd/system")
    }

    /// `systemctl is-active` — "active", "inactive", "failed", "activating"…
    static var activeState: String {
        Shell.run("systemctl", ["is-active", Layout.serviceName]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isActive: Bool { activeState == "active" }

    static var isEnabled: Bool {
        Shell.run("systemctl", ["is-enabled", Layout.serviceName]).out
            .trimmingCharacters(in: .whitespacesAndNewlines) == "enabled"
    }

    static func control(_ verb: String) throws {
        try requireSystemd()
        let result = Shell.run("systemctl", [verb, Layout.serviceName])
        guard result.ok else {
            throw CLIError.message("""
                systemctl \(verb) \(Layout.serviceName) failed:
                \(result.err.isEmpty ? result.out : result.err)
                """.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func daemonReload() throws {
        try requireSystemd()
        let result = Shell.run("systemctl", ["daemon-reload"])
        guard result.ok else { throw CLIError.message("systemctl daemon-reload failed: \(result.err)") }
    }

    /// Last `lines` journal entries, or follow.
    static func journal(lines: Int, follow: Bool) throws {
        try requireSystemd()
        var arguments = ["-u", Layout.serviceName, "-n", "\(lines)", "--no-pager"]
        if follow { arguments.append("-f") }
        let result = Shell.run("journalctl", arguments, passthrough: true)
        // Ctrl-C is how `-f` is meant to end. Foundation reports the RAW signal number for a signalled
        // child, not the shell's 128+n — so checking only for 130 turned Ctrl-C into "exited 2".
        let cleanExits: Set<Int32> = [SIGINT, SIGTERM, 128 + SIGINT, 128 + SIGTERM]
        if !result.ok && !cleanExits.contains(result.status) {
            throw CLIError.message("journalctl exited \(result.status)")
        }
    }

    private static func requireSystemd() throws {
        guard systemdAvailable else { throw CLIError.noSystemd }
    }

    /// Rewrite the drop-in listing the paths the service may write to. `ProtectSystem=strict` makes
    /// everything else read-only, and getting this wrong is silent: every download fails to write.
    static func writePathsDropIn(_ effective: Effective) throws {
        var paths = [Layout.stateDir, effective.saveDir]
        paths.append((effective.databasePath as NSString).deletingLastPathComponent)
        if let watch = effective.watchDir { paths.append(watch) }
        // Deduplicate while keeping order, so the file is stable across runs and
        // a diff of it means something changed.
        var seen = Set<String>()
        let unique = paths.filter { !$0.isEmpty && seen.insert($0).inserted }

        let body = """
        # Written by `goel config` — do not edit.
        #
        # The unit runs with ProtectSystem=strict, so every writable location has
        # to be named. These come from \(Layout.configFile): the state directory,
        # the download folder, the database's directory, and the watch folder.
        # Re-run `goel config sync` to refresh it from the config file.
        [Service]
        ReadWritePaths=\(unique.map(quoted).joined(separator: " "))

        """
        try FileManager.default.createDirectory(atPath: Layout.dropInDir,
                                                withIntermediateDirectories: true)
        try body.write(toFile: Layout.dropInFile, atomically: true, encoding: .utf8)
    }

    /// `ReadWritePaths=` is whitespace-separated, so a folder with a space in its name
    /// silently becomes two paths that do not exist. systemd accepts double quotes.
    private static func quoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@,+"))
        guard !path.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return path }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
