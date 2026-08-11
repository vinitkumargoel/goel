import Foundation
#if canImport(Glibc)
import Glibc
#endif

extension GoelCLI {

    struct Check {
        enum Result { case pass(String), warn(String), fail(String) }
        let name: String
        let result: Result
    }

    static func doctor() throws {
        var checks: [Check] = []
        let manager = FileManager.default

        // The install-layout and library checks are the *installer's* contract — a portable
        // install (macOS, or GoelDaemon run by hand) has no /opt/goel to hold to account.
        #if os(Linux)
        if Layout.systemInstallPresent {
            for path in [Layout.daemonBinary, Layout.runScript, Layout.cliLink, Layout.configFile] {
                checks.append(Check(
                    name: path,
                    result: manager.fileExists(atPath: path)
                        ? .pass("present")
                        : .fail("missing — reinstall: curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh")))
            }

            if Shell.which("ldd") != nil {
                var unresolved: [String] = []
                for binary in [Layout.daemonBinary, Layout.installRoot + "/bin/goel"]
                        where manager.fileExists(atPath: binary) {
                    unresolved += Shell.run("ldd", [binary]).out
                        .split(separator: "\n")
                        .filter { $0.contains("not found") }
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
                unresolved = Array(Set(unresolved)).sorted()
                checks.append(Check(
                    name: "shared libraries",
                    result: unresolved.isEmpty
                        ? .pass("all resolved")
                        : .fail("""
                            unresolved:
                            \(unresolved.map { "        " + $0 }.joined(separator: "\n"))
                            \(missingLibraryAdvice)
                            """)))
            }
        }
        #endif

        let configPath = Layout.resolveConfigPath()
        checks.append(Check(
            name: "config",
            result: manager.fileExists(atPath: configPath)
                ? .pass(configPath)
                : ProcessInfo.processInfo.environment["GOEL_TOKEN"]?.isEmpty == false
                    ? .pass("none — GOEL_TOKEN comes from the environment")
                    : .warn("no config yet at \(configPath) — `goel config set token <token>` creates it")))

        // Preserve the real reason: "config unreadable, use sudo" and "not installed"
        // point at opposite remedies, and doctor exists to name the right one.
        let effective: Effective
        do {
            effective = try Effective.load()
        } catch {
            report(checks)
            throw error
        }
        let config = try? ConfigFile()

        // The config file holds the portal password in plaintext; nobody else needs to read it.
        if let attributes = try? manager.attributesOfItem(atPath: configPath),
           let mode = attributes[.posixPermissions] as? NSNumber {
            let permissions = mode.uint16Value & 0o777
            checks.append(Check(
                name: "config permissions",
                result: permissions & 0o077 == 0
                    ? .pass(String(format: "%04o", permissions))
                    : .warn(String(format: "%04o — holds the portal password in plaintext; ", permissions)
                            + "tighten with: chmod 600 \(configPath)")))
        }

        if Service.systemdAvailable {
            let state = Service.activeState
            checks.append(Check(
                name: "service",
                result: state == "active" ? .pass("active")
                      : state == "failed" ? .fail("failed — `goel logs` for the reason")
                      : .warn("\(state) — `goel start` to start it")))
            checks.append(Check(
                name: "starts at boot",
                result: Service.isEnabled ? .pass("enabled")
                                          : .warn("disabled — `goel enable` to survive a reboot")))
            checks.append(Check(
                name: "writable-paths drop-in",
                result: dropIn(effective)))
        } else {
            checks.append(Check(
                name: "service",
                result: .warn("no systemd — run `GoelDaemon` yourself; "
                              + "the portal check below says whether one is up")))
        }

        for (label, path) in [("downloads", effective.saveDir),
                              ("database dir", (effective.databasePath as NSString).deletingLastPathComponent)] {
            checks.append(Check(name: label, result: writability(path)))
        }

        #if os(Linux)
        checks.append(Check(name: "port \(effective.port)", result: portCheck(effective)))
        #endif

        checks.append(Check(name: "ffmpeg", result: ffmpeg()))

        // The daemon silently refuses a passwordless LAN bind and falls back to loopback.
        if effective.allowLAN {
            let hasPassword = (config?.value(forEnv: "GOEL_PASSWORD")?.isEmpty == false)
                || (ProcessInfo.processInfo.environment["GOEL_PASSWORD"]?.isEmpty == false)
            checks.append(Check(
                name: "LAN exposure",
                result: !effective.requireAuth
                    ? .fail("sign-in is off while bound to the LAN — anyone who can reach the "
                            + "port owns the queue. `sudo goel config set auth true`")
                    : hasPassword
                        ? .warn("on, over plain HTTP — the password and token cross the network "
                                + "unencrypted. Put nginx or caddy in front for TLS.")
                        : .fail("requested, but no password is set, so the daemon binds loopback "
                                + "only. `sudo goel config set password <password>`")))
        }

        // Probe regardless of how (or whether) the daemon is service-managed: a portable
        // GoelDaemon is exactly as real as a systemd one. Severity policy: unreachable is
        // a FAILURE only when systemd claims the service is up (something is lying);
        // otherwise it's a warning — doctor judges the install, and "the daemon isn't
        // started" is a state, not a defect. Liveness gating belongs to `goel status
        // --json`, which exits non-zero when the portal is unreachable.
        do {
            let rows = try API(port: effective.port, token: try effective.token()).tasks()
            checks.append(Check(name: "portal API", result: .pass("responding, \(rows.count) task(s)")))
        } catch let error as CLIError {
            checks.append(Check(
                name: "portal API",
                result: Service.isActive
                    ? .fail(error.text)
                    : .warn("not responding — "
                            + (Service.systemdAvailable ? "`goel start` to start the service"
                                                        : "start GoelDaemon, then re-run doctor"))))
        }

        report(checks)

        let failures = checks.filter { if case .fail = $0.result { return true } else { return false } }
        if !failures.isEmpty {
            Out.line()
            Out.error("\(failures.count) problem(s) found.")
            exit(1)
        }
    }

    static var missingLibraryAdvice: String {
        """
        Find what provides each one and install it:
                            sudo apt-get install -y apt-file && sudo apt-file update
                            apt-file search <library>
                        libtorrent and Boost ship inside /opt/goel/lib, so if one of THOSE is
                        missing the release is incomplete — reinstall rather than hunt for a package.
        """
    }

    /// A stale drop-in is as broken as a missing one: the service starts and every write is denied.
    static func dropIn(_ effective: Effective) -> Check.Result {
        guard let contents = try? String(contentsOfFile: Layout.dropInFile, encoding: .utf8) else {
            return .warn("missing — the unit runs ProtectSystem=strict, so downloads will fail "
                         + "to write. Regenerate it: sudo goel config sync")
        }
        var expected = [Layout.stateDir, effective.saveDir,
                        (effective.databasePath as NSString).deletingLastPathComponent]
        if let watch = effective.watchDir { expected.append(watch) }
        let absent = expected.filter { !contents.contains($0) }
        guard absent.isEmpty else {
            return .fail("out of date — it does not cover \(absent.joined(separator: ", ")). "
                         + "Writes there will be denied. Fix: sudo goel config sync")
        }
        return .pass(Layout.dropInFile)
    }

    /// System install: tests the *service user*, not root — `isWritableFile` under sudo
    /// answers the wrong question. Portable install: the daemon runs as this user, so a
    /// plain current-user probe is the honest check.
    static func writability(_ path: String) -> Check.Result {
        let manager = FileManager.default
        guard Layout.systemInstallPresent, Service.systemdAvailable else {
            guard manager.fileExists(atPath: path) else {
                return .warn("\(path) does not exist yet — the daemon creates it on start")
            }
            return manager.isWritableFile(atPath: path)
                ? .pass("\(path) — writable")
                : .fail("\(path) is not writable by this user, so every download will fail there.")
        }
        guard manager.fileExists(atPath: path) else {
            return .fail("\(path) does not exist — sudo mkdir -p \(path) && "
                         + "sudo chown \(Layout.serviceUser): \(path)")
        }
        guard let id = Shell.which("id"), !id.isEmpty,
              Shell.run("id", ["-u", Layout.serviceUser]).ok else {
            return .warn("\(path) exists, but there is no \(Layout.serviceUser) user to check against")
        }
        let probe = path + "/.goel-write-probe"
        var attempt = Shell.run("runuser", ["-u", Layout.serviceUser, "--", "touch", probe])
        if attempt.status == 127 {
            attempt = Shell.run("sudo", ["-n", "-u", Layout.serviceUser, "touch", probe])
        }
        if attempt.status == 127 {
            return .warn("\(path) exists; couldn't test it as \(Layout.serviceUser) "
                         + "(neither runuser nor sudo available)")
        }
        defer { try? manager.removeItem(atPath: probe) }
        return attempt.ok
            ? .pass("\(path) — writable by \(Layout.serviceUser)")
            : .fail("\(path) is NOT writable by \(Layout.serviceUser), so every download will fail. "
                    + "Fix: sudo chown -R \(Layout.serviceUser): \(path)")
    }

    static func ffmpeg() -> Check.Result {
        #if os(macOS)
        let advice = "brew install ffmpeg"
        #else
        let advice = "sudo apt install ffmpeg"
        #endif
        guard let path = Shell.which("ffmpeg"), !path.isEmpty else {
            return .warn("not installed — HLS (.m3u8) downloads will fail. "
                         + "Everything else works. Fix: \(advice)")
        }
        return .pass("\(path)")
    }

    /// Must retry: systemd reports the unit active as soon as it forks, so one instant probe lies.
    static func portCheck(_ effective: Effective) -> Check.Result {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let listening = Shell.run("ss", ["-ltnpH"])
            guard listening.ok else { return .warn("couldn't check (ss unavailable)") }
            let matching = listening.out.split(separator: "\n").filter {
                $0.contains(":\(effective.port) ")
            }
            if !matching.isEmpty {
                guard matching.contains(where: { $0.contains("GoelDaemon") }) else {
                    return .fail("held by another process — change it with `sudo goel config set port <n>`")
                }
                let boundLAN = matching.contains {
                    $0.contains("0.0.0.0:\(effective.port)") || $0.contains("*:\(effective.port)")
                }
                return .pass("listening on \(boundLAN ? "0.0.0.0" : "127.0.0.1")")
            }
            // Must stay inside the loop: it catches a daemon that exits while we wait.
            guard Service.isActive else {
                return .warn("nothing listening (the service is not running)")
            }
            guard Date() < deadline else {
                return .fail("nothing is listening although the service is active — `goel logs`")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    static func report(_ checks: [Check]) {
        Out.line(Out.bold("goel doctor"))
        Out.line()
        for check in checks {
            switch check.result {
            case .pass(let detail):
                Out.line("  \(Out.green("✓"))  \(check.name)\(detail.isEmpty ? "" : Out.dim(" — \(detail)"))")
            case .warn(let detail):
                Out.line("  \(Out.amber("!"))  \(check.name) — \(detail)")
            case .fail(let detail):
                Out.line("  \(Out.red("✗"))  \(check.name) — \(detail)")
            }
        }
    }

    static func uninstall(_ arguments: [String]) throws {
        try requireRoot()
        let purge = arguments.contains("--purge")
        let assumeYes = arguments.contains("--yes") || arguments.contains("-y")

        Out.line(Out.bold("This will remove:"))
        Out.line("  the \(Layout.serviceName) service, \(Layout.unitFile), \(Layout.dropInDir)")
        Out.line("  \(Layout.installRoot) and \(Layout.cliLink)")
        if purge {
            Out.line(Out.red("  \(Layout.configDir) — your configuration"))
            Out.line(Out.red("  \(Layout.stateDir) — the queue database AND downloaded files"))
            Out.line(Out.red("  the \(Layout.serviceUser) system user"))
            // A configured save-dir can be anyone's home directory, so it is never deleted.
            if let config = try? ConfigFile(),
               case let effective = Effective(config),
               !effective.saveDir.hasPrefix(Layout.stateDir) {
                Out.line(Out.dim("  keeping \(effective.saveDir) — downloads there are left alone; "
                                 + "delete it yourself if you want it gone."))
            }
        } else {
            Out.line(Out.dim("  keeping \(Layout.configDir) and \(Layout.stateDir) "
                             + "(config, queue and downloads). Add --purge to delete those too."))
        }

        if !assumeYes {
            Out.line()
            // Deletion is not undoable: require a typed word, not a y/n a reflex keypress satisfies.
            let expected = purge ? "purge" : "uninstall"
            Out.line("Type \(Out.bold(expected)) to confirm, anything else to abort:")
            let answer = readLine(strippingNewline: true) ?? ""
            guard answer == expected else {
                Out.line("Aborted — nothing was changed.")
                return
            }
        }

        // Collect, don't throw: stopping at the first problem leaves a half-removed install.
        var problems: [String] = []

        if Service.systemdAvailable {
            let disable = Shell.run("systemctl", ["disable", "--now", Layout.serviceName])
            if !disable.ok {
                problems.append("the service could not be stopped and disabled: "
                                + (disable.err.isEmpty ? "systemctl exited \(disable.status)" : disable.err))
            }
        }
        for path in [Layout.unitFile, Layout.dropInFile, Layout.dropInDir,
                     Layout.cliLink, Layout.installRoot] {
            problems.append(contentsOf: remove(path))
        }
        if Service.systemdAvailable {
            let reload = Shell.run("systemctl", ["daemon-reload"])
            if !reload.ok { problems.append("systemctl daemon-reload failed: \(reload.err)") }
            // Deliberately unchecked: reset-failed exits non-zero when nothing is failed.
            Shell.run("systemctl", ["reset-failed", Layout.serviceName])
        }
        if purge {
            for path in [Layout.configDir, Layout.stateDir] {
                problems.append(contentsOf: remove(path))
            }
            let userdel = Shell.run("userdel", [Layout.serviceUser])
            if !userdel.ok {
                problems.append("""
                    the \(Layout.serviceUser) user could not be deleted: \
                    \(userdel.err.isEmpty ? "userdel exited \(userdel.status)" : userdel.err)
                        Something may still be running as it — check `pgrep -u \(Layout.serviceUser)`, \
                    then `sudo userdel \(Layout.serviceUser)`.
                    """)
            }
        }

        Out.line()
        if problems.isEmpty {
            Out.line(Out.green("Removed."))
        } else {
            Out.line(Out.amber("Mostly removed — \(problems.count) step(s) did not complete:"))
            for problem in problems { Out.line("  \(Out.amber("!")) \(problem)") }
            Out.line()
            Out.line(Out.dim("Everything else is gone. Fix the above and re-run "
                             + "`sudo goel uninstall\(purge ? " --purge" : "")` to finish."))
        }
        if !purge {
            Out.line(Out.dim("\(Layout.configDir) and \(Layout.stateDir) were kept. "
                             + "Reinstalling picks up where you left off."))
        }
    }

    private static func remove(_ path: String) -> [String] {
        let manager = FileManager.default
        // attributesOfItem too: it doesn't follow links, so a dangling one still counts as present.
        guard manager.fileExists(atPath: path)
                || (try? manager.attributesOfItem(atPath: path)) != nil else { return [] }
        do {
            try manager.removeItem(atPath: path)
            return []
        } catch {
            return ["\(path) could not be removed: \(error.localizedDescription)"]
        }
    }

    static func printHelp() {
        Out.line("""
        \(Out.bold("goel")) — download anything, from the terminal, through the Goel° engine.

        \(Out.bold("Download")) — curl-parity: give goel a URL and it blocks until the file is on disk.
          goel <url>…                  download and wait; prints the saved path when done
              --detach, -D             just queue it and return (same as `goel add`)
              --timeout SECONDS, -t    give up waiting after this long (download continues)
              --folder DIR, -d         save somewhere other than the default
              --priority skip|low|normal|high, -p
              --paused                 add without starting (implies no waiting)
              --net SPEC, -n           auto | single:<iface> | aggregate | aggregate:<a>,<b>
              --json                   machine-readable result (final task details)
          Ctrl-C detaches — the download itself keeps going on the daemon.
          Sources: http(s), ftp(s), sftp, magnet links, .torrent and .m3u8 URLs.

        \(Out.bold("Queue"))
          goel add <url>…              queue downloads and return (add --wait/-w to block)
          goel list [--all] [--json]   every download in one command (--all includes finished)
          goel status [--json]         service state, portal URL, queue summary
          goel pause <id|all>          pause one download, or everything
          goel resume <id|all>         resume one download, or everything
          goel retry <id>              retry a failed download
          goel rm <id> [--data]        remove; --data deletes the files too
          goel adapters                network interfaces and the aggregation policy

        \(Out.bold("Web portal")) — the same queue in the browser.
          goel url                     portal URL including the API token
          goel web                     print it and open the browser

        \(Out.bold("Service")) (Linux/systemd installs)
          goel start | stop | restart  control the service
          goel enable | disable        start at boot, or not
          goel logs [-f] [-n N]        journal for the service

        \(Out.bold("Configuration"))
          goel config                  list every setting and its current value
          goel config get <key>        print one value
          goel config set <key> <val>  change one value, then restart if running
          goel config unset <key>      revert to the daemon's default
          goel config sync             rewrite the unit's writable paths from config
          goel token [show|rotate]     the API token

        \(Out.bold("Maintenance"))
          goel doctor                  check the install and say how to fix what is wrong
          goel uninstall [--purge]     remove the service (--purge also deletes data)
          goel version

        \(Out.bold("Settings"))
        \(settings.map { "  \($0.key.padding(toLength: 22, withPad: " ", startingAt: 0))\($0.summary)" }
            .joined(separator: "\n"))

        \(Out.bold("Exit codes"))  0 ok · 1 error · 2 usage · 3 refused or failed · 4 wait timeout ·
        130 detached (Ctrl-C).  GOEL_PORT / GOEL_TOKEN / GOEL_CONFIG in the environment
        override the config file, so agents can point goel at any local daemon.

        System installs keep the config and token root-only, hence sudo there; a
        portable install (`~/.config/goel/config`) needs none. Full reference:
        https://github.com/vinitkumargoel/goel/blob/main/docs/cli.md
        """)
    }
}
