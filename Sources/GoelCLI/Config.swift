import Foundation

struct Setting {
    let key: String
    let env: String
    let summary: String
    /// Secrets are never printed back: `goel config` may show `set`/`unset`, never the value.
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

    /// These paths get chowned and made writable to a process parsing untrusted torrent metadata.
    private static let forbiddenRoots: Set<String> = [
        "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32",
        "/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys",
        "/tmp", "/usr", "/var", "/home",
    ]

    static func absolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return "must be an absolute path" }
        if value.contains("\u{0}") { return "must not contain a null byte" }
        // Normalise before the check, or /etc/, //etc and /etc/. all slip past forbiddenRoots.
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
        // The portal is LAN-reachable and only rate-limited, so a trivial password is the whole defence.
        if value.count < 8 { return "too short — use at least 8 characters" }
        return nil
    }

    /// Duplicates `NetworkSelection.isValidInterfaceName`: importing GoelCore drags in libtorrent/libcurl.
    static func isInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 15 else { return false }   // IFNAMSIZ - 1
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func interfaceList(_ value: String) -> String? {
        let names = value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let bad = names.first(where: { !isInterfaceName($0) }) else { return nil }
        return "‘\(bad)’ is not an interface name — see `goel adapters`"
    }

    /// Local typo check only — the daemon re-parses the spec and is the authority.
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

/// The operator owns this file: comments, ordering and unknown keys must survive every write.
struct ConfigFile {
    private(set) var lines: [String]
    let path: String

    init(path: String = Layout.resolveConfigPath()) throws {
        self.path = path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if FileManager.default.fileExists(atPath: path) { throw CLIError.needsRoot }
            throw CLIError.notInstalled(missing: path)
        }
        // Drop exactly one trailing empty component; `save()` re-adds exactly one newline.
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        self.lines = parts
    }

    /// A config that does not exist yet: `save()` will create it. Used by `config set`
    /// on a fresh portable install, and by env-only operation (GOEL_TOKEN set, no file).
    init(creatingAt path: String) {
        self.path = path
        self.lines = []
    }

    /// nil means absent; `""` is a distinct value — systemd reads `KEY=` as set-but-empty.
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

    /// Temp file + `rename`: a crash mid-write must leave the old config, not a truncated one.
    func save() throws {
        let body = lines.joined(separator: "\n") + "\n"
        let temporary = path + ".tmp.\(getpid())"

        // 0600 at creation: narrowing later leaves a window where the plaintext password is readable.
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
        // O_CREAT honours the umask, so the mode must be verified, never assumed.
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
        // systemd strips one layer of matching quotes; mirror it or quoted values read back wrong.
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : (key, value)
    }

    /// systemd splits EnvironmentFile values on whitespace and honours mid-line `#`, so quote anything else.
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

struct Effective {
    var port: Int
    var databasePath: String
    var saveDir: String
    var watchDir: String?
    var allowLAN: Bool
    var requireAuth: Bool
    var username: String
    var tokenFromConfig: String?

    init(_ config: ConfigFile,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        // The process environment outranks the file, mirroring how the daemon itself reads
        // these keys — so `GOEL_PORT=9090 goel list` talks to the right portal.
        func raw(_ env: String) -> String? {
            if let fromEnv = environment[env], !fromEnv.isEmpty {
                return fromEnv
            }
            return config.value(forEnv: env).flatMap { $0.isEmpty ? nil : $0 }
        }
        func bool(_ env: String, _ fallback: Bool) -> Bool {
            guard let value = raw(env)?.lowercased() else { return fallback }
            return ["1", "true", "yes", "on"].contains(value)
        }
        port = raw("GOEL_PORT").flatMap(Int.init) ?? Layout.defaultPort
        // Fall back to the DAEMON's paths, not a fresh install's, or unset keys point at unwritten files.
        databasePath = raw("GOEL_DB")
            ?? Self.daemonHome + "/.local/share/goel-downloader/queue.sqlite"
        saveDir = raw("GOEL_SAVE_DIR") ?? Self.daemonHome + "/Downloads"
        watchDir = raw("GOEL_WATCH_DIR")
        // Must stay identical to the daemon's defaults in Sources/GoelDaemon/main.swift.
        allowLAN = bool("GOEL_ALLOW_LAN", false)
        requireAuth = bool("GOEL_REQUIRE_AUTH", true)
        username = raw("GOEL_USERNAME") ?? "admin"
        tokenFromConfig = raw("GOEL_TOKEN")
    }

    /// Loads config the way every queue command needs it: file if present, else pure
    /// environment — an agent with GOEL_TOKEN (and maybe GOEL_PORT) exported needs no file.
    static func load() throws -> Effective {
        do {
            return Effective(try ConfigFile())
        } catch let error as CLIError {
            guard case .notInstalled = error,
                  ProcessInfo.processInfo.environment["GOEL_TOKEN"]?.isEmpty == false else {
                throw error
            }
            return Effective(ConfigFile(creatingAt: Layout.resolveConfigPath()))
        }
    }

    static let daemonHome: String = {
        if let entry = getpwnam(Layout.serviceUser), let directory = entry.pointee.pw_dir {
            let home = String(cString: directory)
            if !home.isEmpty { return home }
        }
        // No `goel` service user means a portable install: the daemon runs as this user.
        if !Layout.systemInstallPresent { return NSHomeDirectory() }
        return Layout.stateDir
    }()

    func token() throws -> String {
        if let configured = tokenFromConfig { return configured }
        let path = Layout.tokenFile(databasePath: databasePath)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Three distinct situations, three distinct remedies: file exists but this
            // user can't read it (permissions), file genuinely absent (daemon never
            // started), and a system path we can't even see into (use sudo).
            if FileManager.default.fileExists(atPath: path) {
                if geteuid() != 0, !path.hasPrefix(NSHomeDirectory()) { throw CLIError.needsRoot }
                throw CLIError.message("""
                    \(path) exists but couldn’t be read — check its ownership and permissions \
                    (the daemon writes it 0600 as the user it runs as).
                    """)
            }
            if geteuid() != 0, !path.hasPrefix(NSHomeDirectory()) { throw CLIError.needsRoot }
            throw CLIError.message("""
                no API token yet — \(path) does not exist.
                The daemon writes it on first successful start; try `goel start` \
                (or run GoelDaemon), then `goel status`.
                """)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CLIError.message("\(path) is empty") }
        return token
    }
}
