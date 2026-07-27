import Foundation

/// One configurable setting: the friendly name an operator types, the
/// environment variable the daemon actually reads, and how to validate it.
struct Setting {
    let key: String
    let env: String
    let summary: String
    /// Secrets are accepted but never printed back — `goel config` shows `set`
    /// or `unset` for these, never the value. An operator reading config over a
    /// shared screen, or pasting output into a bug report, must not leak the
    /// portal password or the API token by doing the obvious thing.
    let secret: Bool
    let validate: (String) -> String?

    init(_ key: String, _ env: String, _ summary: String,
         secret: Bool = false, validate: @escaping (String) -> String? = { _ in nil }) {
        self.key = key
        self.env = env
        self.summary = summary
        self.secret = secret
        self.validate = validate
    }
}

enum Validators {
    static func port(_ value: String) -> String? {
        guard let n = Int(value), (1...65535).contains(n) else {
            return "not a port number (1–65535)"
        }
        if n < 1024 {
            return "privileged ports (<1024) need extra capabilities the unit does not grant; "
                 + "put a reverse proxy in front instead"
        }
        return nil
    }

    static func bool(_ value: String) -> String? {
        let ok = ["true", "false", "yes", "no", "on", "off", "1", "0"]
        return ok.contains(value.lowercased()) ? nil : "expected true or false"
    }

    /// Every path accepted here is created, recursively chowned to the service user,
    /// and made writable to a process that parses untrusted torrent metadata — so a
    /// leading `/` is not a sufficient check on its own.
    private static let forbiddenRoots: Set<String> = [
        "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32",
        "/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys",
        "/tmp", "/usr", "/var", "/home",
    ]

    static func absolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return "must be an absolute path" }
        if value.contains("\u{0}") { return "must not contain a null byte" }
        // Normalise first, so /etc/, //etc and /etc/. are all caught.
        let normalised = (value as NSString).standardizingPath
        if normalised.contains("..") {
            return "must not contain ‘..’ — give the real path"
        }
        if forbiddenRoots.contains(normalised) {
            return "\(normalised) is a system directory. Use a subdirectory of it "
                 + "(for example \(normalised == "/" ? "/srv/goel" : normalised + "/goel"))"
        }
        return nil
    }

    static func password(_ value: String) -> String? {
        // The portal is reachable over the LAN and its login is rate-limited but
        // not unguessable, so refuse the passwords that make the throttle the
        // only thing standing in the way.
        if value.count < 8 { return "too short — use at least 8 characters" }
        return nil
    }

    /// Mirrors `NetworkSelection.isValidInterfaceName` in GoelCore. Duplicated
    /// rather than imported: the CLI deliberately does not link GoelCore, which
    /// would drag libtorrent and libcurl into a binary that only speaks HTTP.
    static func isInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 15 else { return false }   // IFNAMSIZ - 1
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Interface names, comma-separated. Empty is valid and means "every eligible
    /// interface" — the daemon distinguishes that from the variable being absent.
    static func interfaceList(_ value: String) -> String? {
        let names = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let bad = names.first(where: { !isInterfaceName($0) }) else { return nil }
        return "‘\(bad)’ is not an interface name — see `goel adapters`"
    }

    /// A `--net` spec. Mirrors `NetworkSelection.init(spec:)` in GoelCore; the
    /// daemon re-parses and is the authority, this only catches typos locally.
    static func networkSpec(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.lowercased() == "auto" { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let argument = parts.count > 1 ? String(parts[1]) : ""
        switch parts[0].lowercased() {
        case "single":
            return isInterfaceName(argument.trimmingCharacters(in: .whitespaces))
                ? nil : "‘\(argument)’ is not an interface name"
        case "aggregate":
            return argument.isEmpty ? nil : interfaceList(argument)
        default:
            return "expected auto, single:<iface>, aggregate, or aggregate:<a>,<b>"
        }
    }

    static func streamsPerAdapter(_ value: String) -> String? {
        guard let n = Int(value), (1...8).contains(n) else { return "expected 1–8" }
        return nil
    }

    static func username(_ value: String) -> String? {
        if value.isEmpty { return "must not be empty" }
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) { return "must be one line" }
        return nil
    }
}

/// The settings `goel config` exposes, in the order `goel config` lists them.
let settings: [Setting] = [
    Setting("port", "GOEL_PORT", "Port the web portal listens on", validate: Validators.port),
    Setting("lan", "GOEL_ALLOW_LAN",
            "Serve the portal to the network instead of loopback only",
            validate: Validators.bool),
    Setting("auth", "GOEL_REQUIRE_AUTH", "Require sign-in", validate: Validators.bool),
    Setting("user", "GOEL_USERNAME", "Portal username", validate: Validators.username),
    Setting("password", "GOEL_PASSWORD", "Portal password",
            secret: true, validate: Validators.password),
    Setting("token", "GOEL_TOKEN", "API bearer token", secret: true),
    Setting("save-dir", "GOEL_SAVE_DIR", "Default download folder",
            validate: Validators.absolutePath),
    Setting("db", "GOEL_DB", "Queue database path", validate: Validators.absolutePath),
    Setting("watch-dir", "GOEL_WATCH_DIR", "Folder watched for .torrent files",
            validate: Validators.absolutePath),
    Setting("watch-autostart", "GOEL_WATCH_AUTOSTART",
            "Start watched torrents without confirmation", validate: Validators.bool),
    Setting("aggregation", "GOEL_AGGREGATION",
            "Split each download across several network interfaces",
            validate: Validators.bool),
    Setting("aggregation-adapters", "GOEL_AGGREGATION_ADAPTERS",
            "Interfaces to split across, comma-separated (empty = all eligible)",
            validate: Validators.interfaceList),
    Setting("aggregation-streams", "GOEL_AGGREGATION_STREAMS",
            "Connections opened per interface (1–8)",
            validate: Validators.streamsPerAdapter),
]

func setting(named key: String) -> Setting? {
    settings.first { $0.key == key.lowercased() }
}

/// Reader/writer for `/etc/goel/config`.
///
/// The file is a systemd `EnvironmentFile`, so the format is fixed by systemd:
/// `KEY=value` lines, `#` comments, no shell expansion. Editing it by hand is
/// entirely legitimate — this type exists so that `goel config set` cannot
/// corrupt it, not to take ownership of it. Comments, ordering and unknown keys
/// an operator added are preserved on write.
struct ConfigFile {
    private(set) var lines: [String]
    let path: String

    init(path: String = Layout.configFile) throws {
        self.path = path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            // The file is 0600 root-only, so the usual way to land here is a missing
            // `sudo` — which used to be reported as "does not look installed".
            if FileManager.default.fileExists(atPath: path) { throw CLIError.needsRoot }
            throw CLIError.notInstalled(missing: path)
        }
        // Keep the trailing-newline behaviour stable: split, drop a single
        // trailing empty component, and re-add exactly one newline on write.
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        self.lines = parts
    }

    /// `nil` when the key is absent; `""` is a real, distinct value (systemd
    /// treats `KEY=` as set-but-empty, and the daemon's `env()` falls back to its
    /// default for an empty string, so the distinction is worth keeping).
    func value(forEnv env: String) -> String? {
        for line in lines.reversed() {   // last assignment wins, as systemd does
            guard let (k, v) = Self.split(line), k == env else { continue }
            return v
        }
        return nil
    }

    mutating func set(env: String, to value: String) {
        let rendered = "\(env)=\(Self.quote(value))"
        for index in lines.indices {
            if let (k, _) = Self.split(lines[index]), k == env {
                lines[index] = rendered
                // Drop any later duplicate so the file says one thing.
                lines = lines.enumerated().filter { offset, line in
                    offset <= index || Self.split(line)?.0 != env
                }.map(\.element)
                return
            }
        }
        lines.append(rendered)
    }

    mutating func unset(env: String) {
        lines = lines.filter { Self.split($0)?.0 != env }
    }

    /// Write via a temporary file in the same directory and `rename`, so a full
    /// disk or a crash mid-write leaves the old config intact rather than a
    /// truncated one that would stop the service booting.
    func save() throws {
        let body = lines.joined(separator: "\n") + "\n"
        let temporary = path + ".tmp.\(getpid())"

        // 0600 from the start, not narrowed afterwards: a later chmod leaves a window
        // where the plaintext password is readable, and a chmod that *failed* used to
        // be discarded — renaming a world-readable file into place, reported as success.
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError.message("couldn’t create \(temporary): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(body.utf8))
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw CLIError.message("couldn’t write \(temporary): \(error.localizedDescription)")
        }
        // O_CREAT honours the umask, so verify rather than assume.
        if chmod(temporary, 0o600) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: temporary)
            throw CLIError.message("""
                couldn’t restrict permissions on \(temporary): \(reason)
                Refusing to install a config file holding the portal password in
                plaintext without knowing it is root-only.
                """)
        }
        if rename(temporary, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: temporary)
            throw CLIError.message("couldn’t replace \(path): \(reason)")
        }
    }

    private static func split(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eq)...])
        // systemd strips one layer of matching quotes; mirror that so a value
        // written quoted reads back unquoted.
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : (key, value)
    }

    /// systemd's EnvironmentFile parsing splits on whitespace unless the value is
    /// quoted, and treats `#` as a comment even mid-line. Quote anything that is
    /// not plainly safe, and refuse what cannot be represented at all.
    private static func quote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@,+="))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// The subset of configuration this CLI needs in order to reach the portal.
struct Effective {
    var port: Int
    var databasePath: String
    var saveDir: String
    var watchDir: String?
    var allowLAN: Bool
    var requireAuth: Bool
    var username: String
    var tokenFromConfig: String?

    init(_ config: ConfigFile) {
        func bool(_ env: String, _ fallback: Bool) -> Bool {
            guard let raw = config.value(forEnv: env)?.lowercased(), !raw.isEmpty else {
                return fallback
            }
            return ["1", "true", "yes", "on"].contains(raw)
        }
        port = config.value(forEnv: "GOEL_PORT").flatMap(Int.init) ?? Layout.defaultPort
        // These fall back to what the DAEMON uses, not to what a fresh install writes:
        // after `goel config unset db`, guessing the latter would send `goel token`
        // hunting in a directory the daemon never wrote to.
        databasePath = config.value(forEnv: "GOEL_DB").flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.daemonHome + "/.local/share/goel-downloader/queue.sqlite"
        saveDir = config.value(forEnv: "GOEL_SAVE_DIR").flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.daemonHome + "/Downloads"
        watchDir = config.value(forEnv: "GOEL_WATCH_DIR").flatMap { $0.isEmpty ? nil : $0 }
        // These two mirror the daemon's own defaults in Sources/GoelDaemon/main.swift.
        allowLAN = bool("GOEL_ALLOW_LAN", false)
        requireAuth = bool("GOEL_REQUIRE_AUTH", true)
        username = config.value(forEnv: "GOEL_USERNAME").flatMap { $0.isEmpty ? nil : $0 }
            ?? "admin"
        tokenFromConfig = config.value(forEnv: "GOEL_TOKEN").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The home the daemon's own path defaults are relative to — the `goel` user's,
    /// from the passwd database rather than assumed.
    static let daemonHome: String = {
        if let entry = getpwnam(Layout.serviceUser), let directory = entry.pointee.pw_dir {
            let home = String(cString: directory)
            if !home.isEmpty { return home }
        }
        return Layout.stateDir
    }()

    /// The token to authenticate with: the operator's if they set one, otherwise
    /// the one the daemon generated and wrote next to its database.
    func token() throws -> String {
        if let configured = tokenFromConfig { return configured }
        let path = Layout.tokenFile(databasePath: databasePath)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            if geteuid() != 0 { throw CLIError.needsRoot }
            throw CLIError.message("""
                no API token yet — \(path) does not exist.
                The daemon writes it on first successful start; try `goel start` and `goel status`.
                """)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CLIError.message("\(path) is empty") }
        return token
    }
}
