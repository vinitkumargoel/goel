import Foundation
#if canImport(Glibc)
import Glibc
#endif

@main
struct GoelCLI {

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try dispatch(arguments)
        } catch let error as CLIError {
            Out.error(error.text)
            if case .usage = error { exit(ExitCode.usage) }
            exit(ExitCode.error)
        } catch {
            Out.error("\(error)")
            exit(ExitCode.error)
        }
    }

    static func dispatch(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let rest = Array(arguments.dropFirst())

        // curl-parity: `goel <url>` needs no subcommand — it downloads the thing and waits.
        if looksLikeSource(command) {
            try add(arguments, waitByDefault: true)
            return
        }

        switch command {
        case "help", "--help", "-h":       printHelp()
        case "version", "--version", "-v": printVersion()

        case "status":                     try status(rest)
        case "start", "stop", "restart":   try controlService(command)
        case "enable", "disable":          try enablement(command)
        case "logs":                       try logs(rest)

        case "config":                     try config(rest)
        case "url":                        try printURL()
        case "web":                        try openWeb()
        case "token":                      try token(rest)

        case "add":                        try add(rest, waitByDefault: false)
        case "adapters":                   try adapters()
        case "list", "ls":                 try list(rest)
        case "pause", "resume":            try pauseResume(command, rest)
        case "retry":                      try simpleTaskAction("/api/retry", rest, verb: "retry")
        case "rm", "remove":               try remove(rest)

        case "doctor":                     try doctor()
        case "uninstall":                  try uninstall(rest)

        default:
            throw CLIError.usage("""
                unknown command “\(command)”. Run `goel help` — or, to download something, \
                give a full URL (https://, ftp://, ftps://, sftp://, magnet:).
                """)
        }
    }

    static func status(_ arguments: [String]) throws {
        let effective = try Effective.load()
        if arguments.contains("--json") {
            try statusJSON(effective)
            return
        }

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
            ("config", Layout.resolveConfigPath()),
            ("database", effective.databasePath),
            ("downloads", effective.saveDir),
        ])

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

    /// One self-describing object per run; `reachable` says whether the queue numbers are live.
    static func statusJSON(_ effective: Effective) throws {
        var service: [String: Any] = ["systemd": Service.systemdAvailable]
        if Service.systemdAvailable {
            service["state"] = Service.activeState
            service["enabledAtBoot"] = Service.isEnabled
        }
        var portal: [String: Any] = [
            "url": "http://127.0.0.1:\(effective.port)/",
            "port": effective.port,
            "lan": effective.allowLAN,
            "authRequired": effective.requireAuth,
            "username": effective.username,
        ]
        var queue: [String: Any] = [:]
        var reachable = false
        do {
            let rows = try API(port: effective.port, token: try effective.token()).tasks()
            let active = rows.filter { $0.statusToken == "downloading" }
            reachable = true
            portal["reachable"] = true
            queue["tasks"] = rows.count
            queue["downloading"] = active.count
            queue["downSpeed"] = active.reduce(0) { $0 + $1.downSpeed }
        } catch let error as CLIError {
            portal["reachable"] = false
            portal["error"] = error.text
        }
        let body: [String: Any] = [
            "service": service,
            "portal": portal,
            "queue": queue,
            "paths": [
                "config": Layout.resolveConfigPath(),
                "database": effective.databasePath,
                "downloads": effective.saveDir,
            ],
        ]
        Out.data(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        // Machine callers gate on $?: an unreachable portal must not read as success.
        // (Human `goel status` stays informational — it paints the problem instead.)
        if !reachable { exit(ExitCode.error) }
    }

    /// `goel url` prints the link; `goel web` also opens it where a browser exists.
    static func openWeb() throws {
        let effective = try Effective.load()
        let token = try effective.token()
        let link = "http://127.0.0.1:\(effective.port)/?token=\(token)"
        Out.line(link)
        Out.note("This link contains your API token — treat it as a password.")
        #if os(macOS)
        let wantsBrowser = true
        #else
        let wantsBrowser = ProcessInfo.processInfo.environment["DISPLAY"] != nil
            || ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] != nil
        #endif
        guard wantsBrowser, let launcher = writePortalLauncher(link: link) else { return }
        #if os(macOS)
        _ = Shell.run("/usr/bin/open", [launcher])
        #else
        _ = Shell.run("xdg-open", [launcher])
        #endif
    }

    /// The token must never ride in the opener's argv: `ps` shows argv to every local
    /// user, and exec-auditing tools record it durably. The browser gets a private
    /// redirect file instead (dir 0700, file 0600) — the same trick jupyter uses.
    static func writePortalLauncher(
        link: String,
        directory: String = (Layout.userConfigFile as NSString).deletingLastPathComponent
    ) -> String? {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory) {
            try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        }
        let file = directory + "/open-portal.html"
        let html = """
            <!doctype html><title>Goel\u{00B0}</title>\
            <meta http-equiv="refresh" content="0; url=\(link)">\
            <a href="\(link)">Open the Goel\u{00B0} portal</a>
            """
        guard manager.createFile(atPath: file, contents: Data(html.utf8),
                                 attributes: [.posixPermissions: 0o600]) else {
            Out.note("couldn’t write \(file) — open the printed link yourself.")
            return nil
        }
        return file
    }

    static func controlService(_ verb: String) throws {
        guard Service.systemdAvailable else { throw CLIError.noSystemd }
        try requireRoot()
        try Service.control(verb)
        // `systemctl start` returns as soon as the unit is spawned, before it binds or dies.
        if verb != "stop" {
            waitForState(seconds: 5)
            let state = Service.activeState
            if state == "active" {
                let effective = try Effective.load()
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
        guard Service.systemdAvailable else { throw CLIError.noSystemd }
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

    static func config(_ arguments: [String]) throws {
        let action = arguments.first ?? "list"
        let rest = Array(arguments.dropFirst())

        switch action {
        case "list", "show":
            let path = Layout.resolveConfigPath()
            // Only a genuinely-absent file falls back to empty; an unreadable one must
            // say "needs root", never render every setting as "(default)".
            let config = try loadConfigOrEmpty(path)
            Out.line(Out.bold("Configuration") + Out.dim(" — \(path)"))
            Out.pairs(settings.map { setting in
                let raw = config.value(forEnv: setting.env)
                let overridden = ProcessInfo.processInfo
                    .environment[setting.env]?.isEmpty == false
                let shown: String
                if setting.secret {
                    let present = (raw?.isEmpty == false) || overridden
                    shown = Out.dim(present ? "(set)" : "(unset)")
                } else if overridden {
                    shown = Out.amber("(from $\(setting.env))")
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
            if setting.secret, setting.key != "token" {
                throw CLIError.message("""
                    \(setting.key) is a secret and is not printed back.
                    Set a new one with `goel config set \(setting.key) <value>`.
                    """)
            }
            // The same precedence every command applies: environment beats the file.
            // Scripts use `config get` to learn the value goel actually operates with —
            // answering from the file alone would contradict `status`, `add`, and list's
            // own "(from $ENV)" marker.
            if let fromEnv = ProcessInfo.processInfo.environment[setting.env], !fromEnv.isEmpty {
                Out.line(fromEnv)
                return
            }
            let config = try loadConfigOrEmpty(Layout.resolveConfigPath())
            guard let value = config.value(forEnv: setting.env), !value.isEmpty else {
                Out.line("(default)")
                return
            }
            Out.line(value)

        case "set":
            guard rest.count >= 2 else { throw CLIError.usage("`goel config set <key> <value>`") }
            let key = rest[0]
            let value = rest.dropFirst().joined(separator: " ")
            guard let setting = setting(named: key) else { throw unknownKey(key) }
            if let complaint = setting.validate(value) {
                throw CLIError.message("\(setting.key): \(complaint)")
            }
            var config = try loadConfigForWriting()
            config.set(env: setting.env, to: value)
            try config.save()
            if ["save-dir", "db", "watch-dir"].contains(setting.key) {
                try syncPaths(Effective(config))
            }
            Out.line(Out.green("Set \(setting.key)") + (setting.secret ? "" : " to \(value)"))
            try restartIfRunning(reason: "for \(setting.key) to take effect")

        case "unset":
            guard let key = rest.first else { throw CLIError.usage("`goel config unset <key>`") }
            guard let setting = setting(named: key) else { throw unknownKey(key) }
            var config = try loadConfigForWriting()
            config.unset(env: setting.env)
            try config.save()
            // Unsetting moves the path to the daemon's default; a stale drop-in leaves it unwritable.
            if ["save-dir", "db", "watch-dir"].contains(setting.key) {
                try syncPaths(Effective(config))
            }
            Out.line(Out.green("Unset \(setting.key)") + " — the daemon's own default applies")
            try restartIfRunning(reason: "for \(setting.key) to take effect")

        case "sync":
            // The installer must call this, not write the drop-in itself: a mismatch starts cleanly, then every write fails.
            guard Service.systemdAvailable else {
                Out.line(Out.dim("No systemd here — nothing to synchronise. "
                                 + "The daemon creates its own paths on start."))
                return
            }
            try requireRoot()
            try syncPaths(Effective(try ConfigFile()))
            Out.line(Out.green("Writable paths synchronised") + Out.dim(" — \(Layout.dropInFile)"))

        default:
            throw CLIError.usage("`goel config [list|get|set|unset|sync]`")
        }
    }

    /// Absent config reads as empty; unreadable config stays an error (needsRoot).
    static func loadConfigOrEmpty(_ path: String) throws -> ConfigFile {
        do {
            return try ConfigFile(path: path)
        } catch CLIError.notInstalled {
            return ConfigFile(creatingAt: path)
        }
    }

    /// Root is the *system* config's contract; a user-level file just needs its directory.
    static func loadConfigForWriting() throws -> ConfigFile {
        let path = Layout.resolveConfigPath()
        let manager = FileManager.default
        if path == Layout.configFile {
            try requireRoot()
        } else {
            // A non-system path was steered by the environment ($GOEL_CONFIG, $XDG_CONFIG_HOME,
            // $HOME) — variables that can cross a sudo boundary. Root writing secrets to a
            // location another user controls is the classic `sudo -E` plant/symlink attack,
            // so root only writes here when the nearest existing ancestor is root's own.
            if geteuid() == 0 {
                var probe = path
                while !manager.fileExists(atPath: probe), probe != "/" {
                    probe = (probe as NSString).deletingLastPathComponent
                }
                var info = stat()
                if stat(probe, &info) == 0,
                   info.st_uid != 0 || (info.st_mode & S_IWOTH) != 0 {
                    throw CLIError.message("""
                        refusing to write \(path) as root — \(probe) is not root-owned
                        (or is world-writable), so another user could control it.
                        Run without sudo, or unset GOEL_CONFIG/XDG_CONFIG_HOME,
                        or use the system config \(Layout.configFile).
                        """)
                }
            }
            let directory = (path as NSString).deletingLastPathComponent
            if !manager.fileExists(atPath: directory) {
                do {
                    // 0700 from the start — this file can carry the portal password.
                    try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                } catch {
                    throw CLIError.message("couldn’t create \(directory): \(error.localizedDescription)")
                }
            }
            if manager.fileExists(atPath: path), !manager.isWritableFile(atPath: path) {
                throw CLIError.needsRoot
            }
        }
        if manager.fileExists(atPath: path) {
            return try ConfigFile(path: path)
        }
        return ConfigFile(creatingAt: path)
    }

    static func syncPaths(_ effective: Effective) throws {
        guard Service.systemdAvailable else {
            // Portable mode: no unit to teach, no service user to own anything —
            // just make sure the places the daemon will write exist. Loudly: a config
            // change that "succeeds" onto an uncreatable path fails later and opaquely.
            let manager = FileManager.default
            var paths = [(effective.databasePath as NSString).deletingLastPathComponent,
                         effective.saveDir]
            if let watchDir = effective.watchDir { paths.append(watchDir) }
            for path in paths where !manager.fileExists(atPath: path) {
                do {
                    try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
                } catch {
                    throw CLIError.message("couldn’t create \(path): \(error.localizedDescription)")
                }
            }
            return
        }
        try Service.writePathsDropIn(effective)
        // The database path is a FILE: creating a directory there leaves SQLite unable to open it.
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
        let effective = try Effective.load()
        let token = try effective.token()
        // This URL embeds an API token — a password in a URL.
        let host = effective.allowLAN ? (primaryIPv4() ?? "127.0.0.1") : "127.0.0.1"
        Out.line("http://\(host):\(effective.port)/?token=\(token)")
        // Warning goes to stderr unconditionally: it matters most when stdout is redirected.
        Out.note("This link contains your API token — treat it as a password.")
    }

    static func token(_ arguments: [String]) throws {
        let action = arguments.first ?? "show"
        switch action {
        case "show":
            let effective = try Effective.load()
            Out.line(try effective.token())
        case "rotate":
            var config = try loadConfigForWriting()
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

    static func api() throws -> (API, Effective) {
        let effective = try Effective.load()
        return (API(port: effective.port, token: try effective.token()), effective)
    }

    struct AddOptions {
        var urls: [String] = []
        var folder: String?
        var priority: String?
        var paused = false
        var network: String?
        var wait = false
        var waitExplicit = false
        var json = false
        var timeoutSeconds: Int?
    }

    static func parseAddArguments(_ arguments: [String], waitByDefault: Bool) throws -> AddOptions {
        var options = AddOptions()
        options.wait = waitByDefault
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--folder", "-d":
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--folder needs a path") }
                options.folder = arguments[index]
            case "--priority", "-p":
                index += 1
                guard index < arguments.count else { throw CLIError.usage("--priority needs a value") }
                let priority = arguments[index].lowercased()
                guard ["skip", "low", "normal", "high"].contains(priority) else {
                    throw CLIError.usage("--priority must be skip, low, normal or high")
                }
                options.priority = priority
            case "--paused":
                options.paused = true
            case "--net", "-n":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--net needs auto, single:<iface>, aggregate, or aggregate:<a>,<b>")
                }
                let network = arguments[index]
                guard Validators.networkSpec(network) == nil else {
                    throw CLIError.usage("--net must be auto, single:<iface>, aggregate, "
                                         + "or aggregate:<a>,<b> — see `goel adapters`")
                }
                options.network = network
            case "--wait", "-w":
                options.wait = true
                options.waitExplicit = true
            case "--detach", "-D":
                options.wait = false
            case "--json":
                options.json = true
            case "--timeout", "-t":
                index += 1
                guard index < arguments.count, let seconds = Int(arguments[index]), seconds > 0 else {
                    throw CLIError.usage("--timeout needs a positive number of seconds")
                }
                options.timeoutSeconds = seconds
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("unexpected option “\(argument)” — see `goel help`")
                }
                options.urls.append(argument)
            }
            index += 1
        }
        if options.paused {
            guard !options.waitExplicit else {
                throw CLIError.usage("--wait and --paused don’t combine — a paused download never finishes")
            }
            options.wait = false   // `goel <url> --paused` means “queue it, held”.
        }
        if options.timeoutSeconds != nil && !options.wait {
            throw CLIError.usage("--timeout only makes sense while waiting — drop it, or add --wait")
        }
        return options
    }

    static func add(_ arguments: [String], waitByDefault: Bool) throws {
        let options = try parseAddArguments(arguments, waitByDefault: waitByDefault)
        guard !options.urls.isEmpty else {
            throw CLIError.usage("`goel add <url> [<url>…] [--folder DIR] [--priority high] "
                                 + "[--paused] [--net single:eth0] [--wait] [--json]`")
        }
        let (client, _) = try api()
        let (result, rawReply): (API.AddResult, Data)
        do {
            (result, rawReply) = try client.add(urls: options.urls, folder: options.folder,
                                                priority: options.priority, paused: options.paused,
                                                network: options.network)
        } catch let error as CLIError {
            // A wholesale 403 (every source refused, bad folder, read-only) is a failed
            // download to the caller, not CLI trouble — exit 3, as the contract says.
            guard case .forbidden(let reason) = error else { throw error }
            if options.json, let body = try? JSONSerialization.data(withJSONObject: ["error": reason]) {
                Out.data(body)   // exit 3 always carries a JSON document in --json mode
            }
            Out.error(reason)
            exit(ExitCode.downloadFailed)
        }
        let ids = result.ids ?? []
        // JSON mode keeps stdout pure JSON: any outcome that stops short of following
        // answers with the portal's own reply; commentary goes to stderr.
        if options.json {
            if !options.wait || result.added == 0 {
                Out.data(rawReply)
                exit(result.added > 0 && result.refused == 0 ? ExitCode.ok
                                                             : ExitCode.downloadFailed)
            }
            if ids.isEmpty {
                Out.data(rawReply)
                Out.error("the daemon didn’t report task IDs (older daemon?) — "
                          + "queued, but goel cannot wait here. `goel list` to watch it.")
                exit(ExitCode.error)
            }
            // stdout stays the detail array; the refusal still has to reach the caller.
            if result.refused > 0 {
                Out.error("refused \(result.refused) of \(options.urls.count) — not a supported "
                          + "download URL, or it resolves to a loopback/metadata address. Exit will be 3.")
            }
        } else {
            if !options.wait && result.added > 0 {
                Out.line(Out.green("Added \(result.added)")
                         + (result.added == 1 ? " download" : " downloads"))
            }
            // `refused` is the portal's internal-address (SSRF) guard, not an error — but it must stay visible.
            if result.refused > 0 {
                Out.line(Out.amber("Refused \(result.refused)") +
                         " — not a supported download URL, or it resolves to a loopback/metadata address.")
            }
            if result.added == 0 {
                if result.refused == 0 {
                    Out.line(Out.amber("Nothing was added — no argument parsed as a download source."))
                }
                exit(ExitCode.downloadFailed)
            }
            if !options.wait {
                exit(result.refused > 0 ? ExitCode.downloadFailed : ExitCode.ok)
            }
            if ids.isEmpty {
                // A daemon from before the `ids` field: queued fine, but there is nothing to follow.
                Out.line(Out.amber("The daemon didn’t report task IDs (older daemon?) — can’t wait here."))
                Out.line(Out.dim("The download is queued; `goel list` to watch it."))
                exit(ExitCode.error)
            }
        }
        try follow(ids: ids, client: client, json: options.json,
                   timeout: options.timeoutSeconds, anyRefused: result.refused > 0)
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
                    // An empty selection means "every eligible interface", not "none of them".
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
        if arguments.contains("--json") {
            let raw = try client.tasksRaw()
            if showAll {
                Out.data(raw)   // verbatim: everything the portal reports, no narrowing
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
                throw CLIError.message("couldn’t read the portal's reply as a task list")
            }
            let active = parsed.filter { ($0["statusToken"] as? String) != "completed" }
            Out.data(try JSONSerialization.data(withJSONObject: active, options: [.sortedKeys]))
            return
        }
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
                    Out.safe(row.name),
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
        for row in rows {
            guard let reason = row.error, !reason.isEmpty else { continue }
            Out.line(Out.red("\(row.id.prefix(8)) failed") + " — \(Out.safe(reason))")
        }
        if hidden > 0 {
            Out.line(Out.dim("\(hidden) finished download\(hidden == 1 ? "" : "s") not shown — `goel list --all` includes them."))
        }
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

    static func resolve(_ partial: String, _ client: API) throws -> String {
        if partial.count == 36 { return partial }   // already a full UUID
        let matches = try client.tasks().map(\.id).filter { $0.hasPrefix(partial) }
        switch matches.count {
        case 1:  return matches[0]
        case 0:  throw CLIError.message("no task whose ID starts with “\(partial)” — `goel list --all`")
        default: throw CLIError.message("“\(partial)” matches \(matches.count) tasks; use more characters")
        }
    }

    static func requireRoot() throws {
        if geteuid() != 0 { throw CLIError.needsRoot }
    }

    static func ensureDirectory(_ path: String, owner: String) throws {
        let manager = FileManager.default

        // `chown -Rh` still follows a symlink NAMED on the command line: a planted link would hand over /etc.
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
            // Never fall back to a weak generator: this value authenticates the API.
            Out.error("couldn’t read /dev/urandom — refusing to invent a token")
            exit(1)
        }
        buffer = [UInt8](data)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    static func primaryIPv4() -> String? {
        #if os(macOS)
        for interface in ["en0", "en1"] {
            let result = Shell.run("/usr/sbin/ipconfig", ["getifaddr", interface])
            let address = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, !address.isEmpty { return address }
        }
        return nil
        #else
        let result = Shell.run("hostname", ["-I"])
        guard result.ok else { return nil }
        return result.out.split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("127.") && $0.contains(".") }
        #endif
    }

    static func printVersion() {
        let version = (try? String(contentsOfFile: Layout.installRoot + "/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Out.line("goel \(version ?? "(unpackaged build)")")
    }
}
