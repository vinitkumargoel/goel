import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// `goel doctor` and `goel uninstall`. Every failure this daemon has is invisible from outside and
/// presents identically as "it doesn't work", so each is checked by name with its fix printed.
extension GoelCLI {

    struct Check {
        enum Result { case pass(String), warn(String), fail(String) }
        let name: String
        let result: Result
    }

    static func doctor() throws {
        var checks: [Check] = []
        let manager = FileManager.default

        // ---- Installation -------------------------------------------------
        for path in [Layout.daemonBinary, Layout.runScript, Layout.cliLink, Layout.configFile] {
            checks.append(Check(
                name: path,
                result: manager.fileExists(atPath: path)
                    ? .pass("present")
                    : .fail("missing — reinstall: curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh")))
        }

        // A missing shared library is the classic "installed but won't start", and the daemon's error goes
        // to the journal. Check both binaries: a CLI that cannot link reports nothing at all.
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

        guard let config = try? ConfigFile() else {
            report(checks)
            throw CLIError.notInstalled(missing: Layout.configFile)
        }
        let effective = Effective(config)

        // Config file permissions: it holds the portal password in plaintext, and systemd reads it as
        // root before dropping privileges, so nothing else needs access.
        if let attributes = try? manager.attributesOfItem(atPath: Layout.configFile),
           let mode = attributes[.posixPermissions] as? NSNumber {
            let permissions = mode.uint16Value & 0o777
            checks.append(Check(
                name: "config permissions",
                result: permissions & 0o077 == 0
                    ? .pass(String(format: "%04o", permissions))
                    : .warn(String(format: "%04o — holds the portal password in plaintext; ", permissions)
                            + "tighten with: sudo chmod 600 \(Layout.configFile)")))
        }

        // ---- Service ------------------------------------------------------
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
            checks.append(Check(name: "service", result: .warn("no systemd — not managed as a service")))
        }

        // ---- Directories the service user must write ----------------------
        for (label, path) in [("downloads", effective.saveDir),
                              ("database dir", (effective.databasePath as NSString).deletingLastPathComponent)] {
            checks.append(Check(name: label, result: writability(path)))
        }

        // ---- Port ---------------------------------------------------------
        checks.append(Check(name: "port \(effective.port)", result: portCheck(effective)))

        // ffmpeg: only HLS needs it, so its absence is a warning rather than a failure — but it is
        // otherwise silent, and an .m3u8 download simply fails later.
        checks.append(Check(name: "ffmpeg", result: ffmpeg()))

        // LAN exposure sanity: the daemon refuses a passwordless LAN bind and falls back to loopback.
        // Right behaviour, and completely silent from outside.
        if effective.allowLAN {
            let hasPassword = (config.value(forEnv: "GOEL_PASSWORD")?.isEmpty == false)
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

        // ---- API ----------------------------------------------------------
        if Service.isActive {
            do {
                let rows = try API(port: effective.port, token: try effective.token()).tasks()
                checks.append(Check(name: "portal API", result: .pass("responding, \(rows.count) task(s)")))
            } catch let error as CLIError {
                checks.append(Check(name: "portal API", result: .fail(error.text)))
            }
        }

        report(checks)

        let failures = checks.filter { if case .fail = $0.result { return true } else { return false } }
        if !failures.isEmpty {
            // Non-zero exit so this is usable in a health check or a CI step.
            Out.line()
            Out.error("\(failures.count) problem(s) found.")
            exit(1)
        }
    }

    /// Deliberately does not name versioned packages — they differ across Ubuntu releases, and
    /// printing a list that is wrong on the operator's own machine is worse than one always-right command.
    static var missingLibraryAdvice: String {
        """
        Find what provides each one and install it:
                            sudo apt-get install -y apt-file && sudo apt-file update
                            apt-file search <library>
                        libtorrent and Boost ship inside /opt/goel/lib, so if one of THOSE is
                        missing the release is incomplete — reinstall rather than hunt for a package.
        """
    }

    /// The drop-in has to exist AND still name the configured paths: a stale one is as broken as a
    /// missing one, and both fail silently — the service starts and every write is denied.
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

    /// Whether the *service user* can write there — not whether root can, which
    /// is what a naïve `isWritableFile` from a sudo'd CLI would tell us.
    static func writability(_ path: String) -> Check.Result {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return .fail("\(path) does not exist — sudo mkdir -p \(path) && "
                         + "sudo chown \(Layout.serviceUser): \(path)")
        }
        guard let id = Shell.which("id"), !id.isEmpty,
              Shell.run("id", ["-u", Layout.serviceUser]).ok else {
            return .warn("\(path) exists, but there is no \(Layout.serviceUser) user to check against")
        }
        // `runuser` is in util-linux on Ubuntu; `sudo -u` is the fallback.
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

    /// ffmpeg is needed to remux HLS (`.m3u8`) into a playable file; everything
    /// else works without it.
    static func ffmpeg() -> Check.Result {
        guard let path = Shell.which("ffmpeg"), !path.isEmpty else {
            return .warn("not installed — HLS (.m3u8) downloads will fail. "
                         + "Everything else works. Fix: sudo apt install ffmpeg")
        }
        return .pass("\(path)")
    }

    /// Is something listening on the configured port, and is it us? Retried for a few seconds because
    /// systemd reports the unit active as soon as it forks, so one instant probe contradicted itself.
    static func portCheck(_ effective: Effective) -> Check.Result {
        let deadline = Date().addingTimeInterval(3)
        while true {
            // `ss` is iproute2, present on any modern Ubuntu.
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
            // Re-read each time round: this also notices a daemon that starts,
            // binds nothing and exits while we are waiting on it.
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

    // MARK: - Uninstall

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
            // A configured save-dir can be anyone's home directory, so it is never deleted — but the line
            // above promises to remove downloads, so say where the survivors actually are.
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
            // Deleting downloads is not undoable, so an explicit word is required
            // rather than a bare y/n that a reflex keypress can satisfy.
            let expected = purge ? "purge" : "uninstall"
            Out.line("Type \(Out.bold(expected)) to confirm, anything else to abort:")
            let answer = readLine(strippingNewline: true) ?? ""
            guard answer == expected else {
                Out.line("Aborted — nothing was changed.")
                return
            }
        }

        // Best-effort by design — stopping at the first problem leaves a half-removed
        // install — but not "success regardless": failures are collected and named.
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
            // Unchecked: reset-failed fails when nothing is failed, the normal case.
            Shell.run("systemctl", ["reset-failed", Layout.serviceName])
        }
        if purge {
            for path in [Layout.configDir, Layout.stateDir] {
                problems.append(contentsOf: remove(path))
            }
            let userdel = Shell.run("userdel", [Layout.serviceUser])
            if !userdel.ok {
                // Nearly always a process still running as the user, so say so.
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

    /// Delete a path; "already absent" is the goal, not a failure.
    private static func remove(_ path: String) -> [String] {
        let manager = FileManager.default
        // attributesOfItem, as well as fileExists: the former does not follow links, so
        // a dangling one still counts as present and gets removed.
        guard manager.fileExists(atPath: path)
                || (try? manager.attributesOfItem(atPath: path)) != nil else { return [] }
        do {
            try manager.removeItem(atPath: path)
            return []
        } catch {
            return ["\(path) could not be removed: \(error.localizedDescription)"]
        }
    }

    // MARK: - Help

    static func printHelp() {
        Out.line("""
        \(Out.bold("goel")) — manage the Goel° download daemon on this machine.

        \(Out.bold("Service"))
          goel status                  service state, portal URL, queue summary
          goel start | stop | restart  control the service
          goel enable | disable        start at boot, or not
          goel logs [-f] [-n N]        journal for the service

        \(Out.bold("Configuration"))
          goel config                  list every setting and its current value
          goel config get <key>        print one value
          goel config set <key> <val>  change one value, then restart if running
          goel config unset <key>      revert to the daemon's default
          goel config sync             rewrite the unit's writable paths from config
          goel url                     portal URL including the API token
          goel token [show|rotate]     the API token

        \(Out.bold("Queue"))
          goel add <url>…              queue downloads
              --folder DIR             save somewhere other than the default
              --priority skip|low|normal|high
              --paused                 add without starting
              --net SPEC               auto | single:<iface> | aggregate | aggregate:<a>,<b>
          goel adapters                network interfaces and the aggregation policy
          goel list [--all]            the queue (--all includes finished)
          goel pause <id|all>          pause one download, or everything
          goel resume <id|all>         resume one download, or everything
          goel retry <id>              retry a failed download
          goel rm <id> [--data]        remove; --data deletes the files too

        \(Out.bold("Maintenance"))
          goel doctor                  check the install and say how to fix what is wrong
          goel uninstall [--purge]     remove the service (--purge also deletes data)
          goel version

        \(Out.bold("Settings"))
        \(settings.map { "  \($0.key.padding(toLength: 22, withPad: " ", startingAt: 0))\($0.summary)" }
            .joined(separator: "\n"))

        Most commands need root, because the config file and the API token are
        readable only by root. Full documentation:
        https://github.com/vinitkumargoel/goel/blob/main/docs/linux.md
        """)
    }
}
