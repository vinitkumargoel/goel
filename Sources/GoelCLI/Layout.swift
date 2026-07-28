import Foundation

/// These paths are a contract with `install.sh`; changing one here means changing it there.
enum Layout {
    static let installRoot = "/opt/goel"
    static let runScript = "/opt/goel/run.sh"
    static let daemonBinary = "/opt/goel/bin/GoelDaemon"

    static let configFile = "/etc/goel/config"
    static let configDir = "/etc/goel"

    static let stateDir = "/var/lib/goel"

    static let serviceName = "goel"
    static let unitFile = "/etc/systemd/system/goel.service"
    /// `ProtectSystem=strict` forces every writable path to be named, so they can't live in the static unit.
    static let dropInDir = "/etc/systemd/system/goel.service.d"
    static let dropInFile = "/etc/systemd/system/goel.service.d/10-paths.conf"

    static let serviceUser = "goel"

    /// A wrapper script, not a symlink: the CLI needs the bundled Swift runtime in `lib/`.
    static let cliLink = "/usr/local/bin/goel"

    /// Bearer token, mode 0600 and owned by the service user — hence sudo on most commands.
    static func tokenFile(databasePath: String) -> String {
        (databasePath as NSString).deletingLastPathComponent + "/portal-token"
    }

    /// Written at install time only; an unset key falls back to the daemon's own default, not these.
    static let defaultDatabase = "/var/lib/goel/queue.sqlite"
    static let defaultSaveDir = "/var/lib/goel/downloads"
    static let defaultPort = 8080
}
