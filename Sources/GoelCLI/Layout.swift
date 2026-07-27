import Foundation

/// Every path and name the installed service occupies, in one place.
///
/// These are the values `install.sh` writes and this CLI reads; they are a
/// contract between the two, so changing one here means changing the installer.
/// A short constant is cheaper to keep in sync than the same literal spelled out
/// in nine command implementations.
enum Layout {
    /// Unpacked release: binaries, the bundled Swift runtime, and `run.sh`.
    static let installRoot = "/opt/goel"
    static let runScript = "/opt/goel/run.sh"
    static let daemonBinary = "/opt/goel/bin/GoelDaemon"

    /// `EnvironmentFile` for the unit — plain `KEY=value` lines the daemon
    /// already understands as its environment, so configuring the service needs
    /// no new format and no parser in the daemon.
    static let configFile = "/etc/goel/config"
    static let configDir = "/etc/goel"

    /// Mutable state: the queue database, the generated portal token, downloads.
    static let stateDir = "/var/lib/goel"

    static let serviceName = "goel"
    static let unitFile = "/etc/systemd/system/goel.service"
    /// Drop-in this CLI owns and rewrites. `ProtectSystem=strict` means the unit
    /// must name every writable path, and the writable paths depend on
    /// configuration — so they cannot live in the static unit.
    static let dropInDir = "/etc/systemd/system/goel.service.d"
    static let dropInFile = "/etc/systemd/system/goel.service.d/10-paths.conf"

    static let serviceUser = "goel"

    /// The `goel` command on PATH. A wrapper script rather than a symlink, because the
    /// CLI needs the bundled Swift runtime in `lib/` on its library path.
    static let cliLink = "/usr/local/bin/goel"

    /// Where the daemon puts the generated bearer token: alongside its database,
    /// mode 0600, owned by the service user. Root can read it; an unprivileged
    /// caller cannot, which is why most commands ask for sudo.
    static func tokenFile(databasePath: String) -> String {
        (databasePath as NSString).deletingLastPathComponent + "/portal-token"
    }

    /// What a fresh install WRITES into the config file. `Effective` falls back to the
    /// daemon's own home-relative values instead — those apply when a key is unset.
    static let defaultDatabase = "/var/lib/goel/queue.sqlite"
    static let defaultSaveDir = "/var/lib/goel/downloads"
    static let defaultPort = 8080
}
