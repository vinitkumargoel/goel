import Foundation
#if canImport(Glibc)
import Glibc
#endif

// `goel` — the admin CLI for the headless Linux daemon. Two backends, no third control channel:
// systemctl + /etc/goel/config for the service, and the portal's JSON API over loopback for the queue.

@main
struct GoelCLI {

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try dispatch(arguments)
        } catch let error as CLIError {
            Out.error(error.text)
            exit(1)
        } catch {
            Out.error("\(error)")
            exit(1)
        }
    }

    static func dispatch(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":       printHelp()
        case "version", "--version", "-v": printVersion()

        case "status":                     try status()
        case "start", "stop", "restart":   try controlService(command)
        case "enable", "disable":          try enablement(command)
        case "logs":                       try logs(rest)

        case "config":                     try config(rest)
        case "url":                        try printURL()
        case "token":                      try token(rest)

        case "add":                        try add(rest)
        case "adapters":                   try adapters()
        case "list", "ls":                 try list(rest)
        case "pause", "resume":            try pauseResume(command, rest)
        case "retry":                      try simpleTaskAction("/api/retry", rest, verb: "retry")
        case "rm", "remove":               try remove(rest)

        case "doctor":                     try doctor()
        case "uninstall":                  try uninstall(rest)

        default:
            throw CLIError.usage("unknown command “\(command)”. Run `goel help`.")
        }
    }

    // MARK: - Service

    static func status() throws {
        let config = try ConfigFile()
        let effective = Effective(config)

        Out.line(Out.bold("Service"))
        if Service.systemdAvailable {
            let state = Service.activeState
            let painted: String
            switch state {
            case "active":               painted = Out.green("active")
            case "activating":           painted = Out.amber("starting")
            case "failed":               painted = Out.red("failed")
            default:                     painted = Out.red(state.isEmpty ? "unknown" : state)
            }
            Out.pairs([
                ("state", painted),
                ("at boot", Service.isEnabled ? "enabled" : Out.amber("disabled")),
                ("unit", Layout.unitFile),
            ])
        } else {
            Out.pairs([("state", Out.amber("no systemd — not managed as a service"))])
        }

        Out.line()
        Out.line(Out.bold("Portal"))
        var portalRows: [(String, String)] = [
            ("url", "http://127.0.0.1:\(effective.port)/"),
            ("network", effective.allowLAN ? "LAN (0.0.0.0)" : "loopback only"),
            ("sign-in", effective.requireAuth ? "required (user: \(effective.username))" : Out.amber("OFF")),
        ]
        if effective.allowLAN, let address = primaryIPv4() {
            portalRows.insert(("lan url", "http://\(address):\(effective.port)/"), at: 1)
        }
        Out.pairs(portalRows)

        Out.line()
        Out.line(Out.bold("Paths"))
        Out.pairs([
            ("config", Layout.configFile),
            ("database", effective.databasePath),
            ("downloads", effective.saveDir),
        ])

        // The queue is only reachable when the daemon is actually up; a stopped
        // service is a normal state, not an error, so say so and stop there.
        guard Service.isActive || !Service.systemdAvailable else {
            Out.line()
            Out.line(Out.dim("Queue unavailable — the service is not running. `goel start` to start it."))
            return
        }
        Out.line()
        Out.line(Out.bold("Queue"))
        do {
            let rows = try API(port: effective.port, token: try effective.token()).tasks()
            let active = rows.filter { $0.statusToken == "downloading" }
            let down = active.reduce(0) { $0 + $1.downSpeed }
            Out.pairs([
                ("tasks", "\(rows.count)"),
                ("downloading", "\(active.count)"),
                ("speed", Out.rate(down)),
            ])
        } catch let error as CLIError {
            Out.pairs([("", Out.amber(error.text))])
        }
    }

    static func controlService(_ verb: String) throws {
        try requireRoot()
        try Service.control(verb)
        // `systemctl start` returns as soon as the unit is spawned, so a bare "started" would be an
        // unchecked claim. Give the daemon a moment to bind (or die) and report what happened.
        if verb != "stop" {
            waitForState(seconds: 5)
            let state = Service.activeState
            if state == "active" {
                let effective = Effective(try ConfigFile())
                Out.line(Out.green("Service \(verb)ed") + " — portal on http://127.0.0.1:\(effective.port)/")
            } else {
                throw CLIError.message("""
                    the unit did not come up (state: \(state.isEmpty ? "unknown" : state)).
                    `goel logs` will say why.
                    """)
            }
        } else {
            Out.line(Out.green("Service stopped"))
        }
    }

    static func enablement(_ verb: String) throws {
        try requireRoot()
        try Service.control(verb)
        Out.line(Out.green(verb == "enable" ? "Will start at boot" : "Will not start at boot"))
    }

    static func logs(_ arguments: [String]) throws {
        var follow = false
        var lines = 50
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "-f", "--follow":
                follow = true
            case "-n", "--lines":
                index += 1
                guard index < arguments.count, let n = Int(arguments[index]), n > 0 else {
                    throw CLIError.usage("-n needs a positive number of lines")
                }
                lines = n
            default:
                throw CLIError.usage("unexpected argument “\(arguments[index])” — see `goel help`")
            }
            index += 1
        }
        try Service.journal(lines: lines, follow: follow)
    }

    // MARK: - Configuration

    static func config(_ arguments: [String]) throws {
        let action = arguments.first ?? "list"
        let rest = Array(arguments.dropFirst())

        switch action {
        case "list", "show":
            let config = try ConfigFile()
            Out.line(Out.bold("Configuration") + Out.dim(" — \(Layout.configFile)"))
            Out.pairs(settings.map { setting in
                let raw = config.value(forEnv: setting.env)
                let shown: String
                if setting.secret {
                    shown = (raw?.isEmpty == false) ? Out.dim("(set)") : Out.dim("(unset)")
                } else if let raw, !raw.isEmpty {
                    shown = raw
                } else {
                    shown = Out.dim("(default)")
                }
                return (setting.key, shown)
            })
            Out.line()
            Out.line(Out.dim("`goel config set <key> <value>` to change one. Secrets are never printed;"))
            Out.line(Out.dim("use `goel token` for the API token."))

        case "get":
            guard let key = rest.first else { throw CLIError.usage("`goel config get <key>`") }
            guard let setting = setting(named: key) else { throw unknownKey(key) }
            let config = try ConfigFile()
            if setting.secret, setting.key != "token" {
                throw CLIError.message("""
                    \(setting.key) is a secret and is not printed back.
                    Set a new one with `goel config set \(setting.key) <value>`.
                    """)
            }
            guard let value = config.value(forEnv: setting.env), !value.isEmpty else {
                Out.line("(default)")
                return
            }
            Out.line(value)

        case "set":
            try requireRoot()
            guard rest.count >= 2 else { throw CLIError.usage("`goel config set <key> <value>`") }
            let key = rest[0]
            let value = rest.dropFirst().joined(separator: " ")
            guard let setting = setting(named: key) else { throw unknownKey(key) }
            if let complaint = setting.validate(value) {
                throw CLIError.message("\(setting.key): \(complaint)")
            }
            var config = try ConfigFile()
            config.set(env: setting.env, to: value)
            try config.save()
            if ["save-dir", "db", "watch-dir"].contains(setting.key) {
                try syncPaths(Effective(config))
            }
            Out.line(Out.green("Set \(setting.key)") + (setting.secret ? "" : " to \(value)"))
            try restartIfRunning(reason: "for \(setting.key) to take effect")

        case "unset":
            try requireRoot()
            guard let key = rest.first else { throw CLIError.usage("`goel config unset <key>`") }
            guard let setting = setting(named: key) else { throw unknownKey(key) }
            var config = try ConfigFile()
            config.unset(env: setting.env)
            try config.save()
            // Unsetting moves the path too, to the daemon's default, so the drop-in
            // has to follow — a stale one leaves that directory unwritable.
            if ["save-dir", "db", "watch-dir"].contains(setting.key) {
                try syncPaths(Effective(config))
            }
            Out.line(Out.green("Unset \(setting.key)") + " — the daemon's own default applies")
            try restartIfRunning(reason: "for \(setting.key) to take effect")

        case "sync":
            // The installer calls this rather than writing the drop-in itself: when
            // the two disagreed, the service started cleanly and every write failed.
            try requireRoot()
            try syncPaths(Effective(try ConfigFile()))
            Out.line(Out.green("Writable paths synchronised") + Out.dim(" — \(Layout.dropInFile)"))

        default:
            throw CLIError.usage("`goel config [list|get|set|unset|sync]`")
        }
    }

    /// Bring the `ReadWritePaths` drop-in and the directories it names in line with
    /// the config file; `ProtectSystem=strict` makes everything else read-only.
    static func syncPaths(_ effective: Effective) throws {
        try Service.writePathsDropIn(effective)
        // The database is a FILE — creating a directory at its path, which is what
        // this used to do, leaves SQLite unable to open it and the daemon dead.
        try ensureDirectory((effective.databasePath as NSString).deletingLastPathComponent,
                            owner: Layout.serviceUser)
        try ensureDirectory(effective.saveDir, owner: Layout.serviceUser)
        if let watchDir = effective.watchDir {
            try ensureDirectory(watchDir, owner: Layout.serviceUser)
        }
        try Service.daemonReload()
    }

    static func unknownKey(_ key: String) -> CLIError {
        .usage("""
            unknown setting “\(key)”. Known settings:
            \(settings.map { "  \($0.key.padding(toLength: 16, withPad: " ", startingAt: 0))\($0.summary)" }
                .joined(separator: "\n"))
            """)
    }

    /// A configuration change only reaches the daemon on restart. Doing it silently would surprise;
    /// not doing it leaves the operator believing a setting applied when it has not.
    static func restartIfRunning(reason: String) throws {
        guard Service.systemdAvailable, Service.isActive else {
            Out.line(Out.dim("The service is not running; the change applies on next start."))
            return
        }
        Out.line(Out.dim("Restarting \(reason)…"))
        try Service.control("restart")
        waitForState(seconds: 5)
        let state = Service.activeState
        if state == "active" {
            Out.line(Out.green("Restarted"))
        } else {
            throw CLIError.message("""
                the change was saved, but the service did not come back up (state: \(state)).
                `goel logs` will say why; `goel config set …` the value back to recover.
                """)
        }
    }

    static func printURL() throws {
        let effective = Effective(try ConfigFile())
        let token = try effective.token()
        // A token in a URL is a password in a URL. Print it, because pairing a
        // phone or a script is the entire point of the command, but say so.
        let host = effective.allowLAN ? (primaryIPv4() ?? "127.0.0.1") : "127.0.0.1"
        Out.line("http://\(host):\(effective.port)/?token=\(token)")
        // stderr, and not conditional on colour: redirecting this into a file or a
        // chat message is exactly when the warning matters, and used to suppress it.
        Out.note("This link contains your API token — treat it as a password.")
    }

    static func token(_ arguments: [String]) throws {
        let action = arguments.first ?? "show"
        switch action {
        case "show":
            let effective = Effective(try ConfigFile())
            Out.line(try effective.token())
        case "rotate":
            try requireRoot()
            var config = try ConfigFile()
            let fresh = randomHex(bytes: 24)
            config.set(env: "GOEL_TOKEN", to: fresh)
            try config.save()
            Out.line(Out.green("New API token generated."))
            Out.line(Out.dim("Anything using the old one — scripts, a paired phone — must be updated."))
            try restartIfRunning(reason: "for the new token to take effect")
            Out.line()
            Out.line(fresh)
        default:
            throw CLIError.usage("`goel token [show|rotate]`")
        }
    }

    // MARK: - Queue

    static func api() throws -> (API, Effective) {
        let effective = Effective(try ConfigFile())
        return (API(port: effective.port, token: try effective.token()), effective)
    }

    static func add(_ arguments: [String]) throws {
        var urls: [String] = []
        var folder: String?
        var priority: String?
        var paused = false
        var network: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--folder", "-d":
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--folder needs a path") }
                folder = arguments[index]
            case "--priority", "-p":
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--priority needs a value") }
                priority = arguments[index].lowercased()
                guard ["skip", "low", "normal", "high"].contains(priority!) else {
                    throw CLIError.usage("--priority must be skip, low, normal or high")
                }
            case "--paused":
                paused = true
            case "--net", "-n":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--net needs auto, single:<iface>, aggregate, or aggregate:<a>,<b>")
                }
                network = arguments[index]
                guard Validators.networkSpec(network!) == nil else {
                    throw CLIError.usage("--net must be auto, single:<iface>, aggregate, "
                                         + "or aggregate:<a>,<b> — see `goel adapters`")
                }
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("unexpected option “\(argument)” — see `goel help`")
                }
                urls.append(argument)
            }
            index += 1
        }
        guard !urls.isEmpty else {
            throw CLIError.usage("`goel add <url> [<url>…] [--folder DIR] [--priority high] "
                                 + "[--paused] [--net single:eth0]`")
        }
        let (client, _) = try api()
        let result = try client.add(urls: urls, folder: folder, priority: priority,
                                    paused: paused, network: network)
        if result.added > 0 {
            Out.line(Out.green("Added \(result.added)") + (result.added == 1 ? " download" : " downloads"))
        }
        // `refused` is the portal's internal-address guard rejecting a URL — a deliberate refusal, not an
        // error — but it must be visible, or a batch quietly does less than asked.
        if result.refused > 0 {
            Out.line(Out.amber("Refused \(result.refused)") +
                     " — not a supported download URL, or it resolves to a loopback/metadata address.")
        }
        if result.added == 0 && result.refused == 0 {
            Out.line(Out.amber("Nothing was added — no argument parsed as a download source."))
        }
    }

    static func adapters() throws {
        let (client, _) = try api()
        let state = try client.network()
        guard !state.adapters.isEmpty else {
            Out.line("No usable network interfaces were found.")
            return
        }
        let selected = Set(state.selected)
        Out.table(
            headers: ["INTERFACE", "NAME", "TYPE", "ADDRESS", "USABLE", "IN SPLIT"],
            rows: state.adapters.map { a in
                [
                    a.name,
                    a.label,
                    a.type,
                    a.ipv4 ?? "—",
                    a.eligible ? Out.green("yes") : Out.amber("no"),
                    // An empty selection means "every eligible interface", so an
                    // empty list must not read as "none of them".
                    (selected.isEmpty || selected.contains(a.name)) && a.eligible ? "yes" : "—",
                ]
            },
            maxWidths: [16, 24, 8, 16, 8, 9]
        )
        Out.line()
        Out.pairs([
            ("aggregation", state.aggregation ? Out.green("on") : "off"),
            ("streams per interface", "\(state.streamsPerAdapter)"),
        ])
        if state.aggregation, let reason = state.reason {
            Out.line(Out.amber("Not splitting right now") + " — \(reason.lowercased()).")
        }
        if state.locked {
            Out.line(Out.dim("GOEL_AGGREGATION is set in \(Layout.configFile); the portal cannot change it permanently."))
        }
        Out.line(Out.dim("Per download: `goel add <url> --net single:\(state.adapters[0].name)` "
                         + "or `--net aggregate`."))
    }

    static func list(_ arguments: [String]) throws {
        let showAll = arguments.contains("--all") || arguments.contains("-a")
        let (client, _) = try api()
        let everything = try client.tasks()
        let rows = showAll ? everything : everything.filter { $0.statusToken != "completed" }
        let hidden = everything.count - rows.count
        guard !rows.isEmpty else {
            Out.line(showAll ? "The queue is empty." : "Nothing active. `goel list --all` includes finished downloads.")
            return
        }
        Out.table(
            headers: ["ID", "NAME", "KIND", "STATUS", "PROGRESS", "SPEED", "ETA", "SIZE"],
            rows: rows.map { row in
                [
                    String(row.id.prefix(8)),
                    row.name,
                    row.kind,
                    row.error == nil ? row.status : Out.red(row.status),
                    Out.percent(row.progress),
                    Out.rate(row.downSpeed),
                    Out.duration(row.etaSeconds),
                    Out.bytes(row.totalBytes),
                ]
            },
            maxWidths: [8, 40, 8, 12, 8, 12, 10, 10]
        )
        Out.line()
        // A red status with no reason is a dead end on a headless box, and the
        // reason is already in the response.
        for row in rows {
            guard let reason = row.error, !reason.isEmpty else { continue }
            Out.line(Out.red("\(row.id.prefix(8)) failed") + " — \(reason)")
        }
        // Without this, a download that just finished looks like it vanished.
        if hidden > 0 {
            Out.line(Out.dim("\(hidden) finished download\(hidden == 1 ? "" : "s") not shown — `goel list --all` includes them."))
        }
        // IDs are UUIDs and the table shows a prefix, so say what the other
        // commands will accept rather than leaving the operator to guess.
        Out.line(Out.dim("Pass the short ID to pause/resume/rm/retry."))
    }

    static func pauseResume(_ verb: String, _ arguments: [String]) throws {
        guard let target = arguments.first else {
            throw CLIError.usage("`goel \(verb) <id|all>`")
        }
        let (client, _) = try api()
        if target == "all" {
            try client.act("/api/\(verb)-all")
            Out.line(Out.green(verb == "pause" ? "Paused everything" : "Resumed everything"))
            return
        }
        let id = try resolve(target, client)
        try client.act("/api/\(verb)", id: id)
        Out.line(Out.green(verb == "pause" ? "Paused" : "Resumed") + " \(target)")
    }

    static func simpleTaskAction(_ route: String, _ arguments: [String], verb: String) throws {
        guard let target = arguments.first else { throw CLIError.usage("`goel \(verb) <id>`") }
        let (client, _) = try api()
        try client.act(route, id: try resolve(target, client))
        Out.line(Out.green("Asked to \(verb)") + " \(target)")
    }

    static func remove(_ arguments: [String]) throws {
        let withData = arguments.contains("--data")
        guard let target = arguments.first(where: { !$0.hasPrefix("-") }) else {
            throw CLIError.usage("`goel rm <id> [--data]`  (--data also deletes downloaded files)")
        }
        let (client, _) = try api()
        let id = try resolve(target, client)
        try client.act("/api/remove", id: id, extra: withData ? ["data": "1"] : [:])
        Out.line(Out.green("Removed") + " \(target)"
                 + (withData ? " and its downloaded files" : " (files kept on disk)"))
    }

    /// Accept the short ID `goel list` prints, and reject a prefix that matches
    /// more than one task rather than acting on an arbitrary one of them.
    static func resolve(_ partial: String, _ client: API) throws -> String {
        if partial.count == 36 { return partial }   // already a full UUID
        let matches = try client.tasks().map(\.id).filter { $0.hasPrefix(partial) }
        switch matches.count {
        case 1:  return matches[0]
        case 0:  throw CLIError.message("no task whose ID starts with “\(partial)” — `goel list --all`")
        default: throw CLIError.message("“\(partial)” matches \(matches.count) tasks; use more characters")
        }
    }

    // MARK: - Helpers

    static func requireRoot() throws {
        if geteuid() != 0 { throw CLIError.needsRoot }
    }

    static func ensureDirectory(_ path: String, owner: String) throws {
        let manager = FileManager.default

        // A recursive chown follows a symlink NAMED on the command line (`-h` only covers links inside
        // the tree), so a planted ~/downloads → /etc would hand the service account /etc. Refuse links.
        var isSymlink = false
        if let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType {
            isSymlink = (type == .typeSymbolicLink)
        }
        if isSymlink {
            throw CLIError.message("""
                \(path) is a symbolic link.
                Refusing to take ownership through it — a link here can redirect a
                recursive chown at any directory on this machine. Give the real path.
                """)
        }

        if !manager.fileExists(atPath: path) {
            do {
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                throw CLIError.message("couldn’t create \(path): \(error.localizedDescription)")
            }
        } else if (try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType)
                    != FileAttributeType.typeDirectory {
            throw CLIError.message("\(path) exists but is not a directory.")
        }

        // A directory the daemon cannot write is the commonest cause of "every
        // download fails instantly", so a failed chown must not report success.
        let chown = Shell.run("chown", ["-Rh", "\(owner):\(owner)", path])
        guard chown.ok else {
            throw CLIError.message("""
                couldn’t give \(owner) ownership of \(path): \
                \(chown.err.isEmpty ? "chown exited \(chown.status)" : chown.err)
                The daemon runs as \(owner) and would fail every download writing there.
                """)
        }
    }

    static func waitForState(seconds: Int) {
        for _ in 0..<(seconds * 5) {
            let state = Service.activeState
            if state == "active" || state == "failed" { return }
            usleep(200_000)
        }
    }

    static func randomHex(bytes count: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        guard let file = FileHandle(forReadingAtPath: "/dev/urandom"),
              let data = try? file.read(upToCount: count), data.count == count else {
            // No fallback to a weak generator: this value authenticates the API,
            // and a predictable token is worse than a failed command.
            Out.error("couldn’t read /dev/urandom — refusing to invent a token")
            exit(1)
        }
        buffer = [UInt8](data)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    /// First non-loopback IPv4, for printing a LAN URL. Best-effort: `hostname -I`
    /// is present on Ubuntu and Debian, and a missing address is not an error.
    static func primaryIPv4() -> String? {
        let result = Shell.run("hostname", ["-I"])
        guard result.ok else { return nil }
        return result.out.split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("127.") && $0.contains(".") }
    }

    static func printVersion() {
        let version = (try? String(contentsOfFile: Layout.installRoot + "/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Out.line("goel \(version ?? "(unpackaged build)")")
    }
}
