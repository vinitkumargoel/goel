import Foundation
import GoelCore
#if canImport(Glibc)
import Glibc
#endif

func env(_ key: String, _ fallback: String) -> String {
    let v = ProcessInfo.processInfo.environment[key]
    return (v?.isEmpty == false) ? v! : fallback
}
func envBool(_ key: String, _ fallback: Bool) -> Bool {
    guard let v = ProcessInfo.processInfo.environment[key]?.lowercased() else { return fallback }
    return ["1", "true", "yes", "on"].contains(v)
}
func stderrLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let home = FileManager.default.homeDirectoryForCurrentUser
let dbPath = env("GOEL_DB", home.appendingPathComponent(".local/share/goel-downloader/queue.sqlite").path)
let portRaw = env("GOEL_PORT", "8080")
guard let port = Int(portRaw), (1...65535).contains(port) else {
    stderrLine("GoelDaemon: fatal — GOEL_PORT '\(portRaw)' is not a valid port (1–65535)")
    exit(1)
}
// Safe default: loopback-only unless the operator opts into LAN — and the server refuses a passwordless LAN bind regardless.
let allowLAN = envBool("GOEL_ALLOW_LAN", false)
let requireAuth = envBool("GOEL_REQUIRE_AUTH", true)
let username = env("GOEL_USERNAME", "admin")
let password = ProcessInfo.processInfo.environment["GOEL_PASSWORD"] ?? ""
let tokenEnv = ProcessInfo.processInfo.environment["GOEL_TOKEN"] ?? ""
let saveDir = env("GOEL_SAVE_DIR", home.appendingPathComponent("Downloads").path)
// Unset GOEL_WATCH_DIR keeps whatever is persisted, so a restart with a trimmed unit file doesn't silently switch the feature off.
let watchDir = env("GOEL_WATCH_DIR", "")
let watchAutoStart = envBool("GOEL_WATCH_AUTOSTART", false)

let aggregationEnv = ProcessInfo.processInfo.environment["GOEL_AGGREGATION"]
let aggregationAdaptersEnv = ProcessInfo.processInfo.environment["GOEL_AGGREGATION_ADAPTERS"]
let aggregationStreamsRaw = env("GOEL_AGGREGATION_STREAMS", "")
if !aggregationStreamsRaw.isEmpty,
   Int(aggregationStreamsRaw).map({ !(1...8).contains($0) }) ?? true {
    stderrLine("GoelDaemon: fatal — GOEL_AGGREGATION_STREAMS '\(aggregationStreamsRaw)' is not 1–8")
    exit(1)
}
let aggregationAdapters = (aggregationAdaptersEnv ?? "")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
if let bad = aggregationAdapters.first(where: { !NetworkSelection.isValidInterfaceName($0) }) {
    stderrLine("GoelDaemon: fatal — GOEL_AGGREGATION_ADAPTERS contains '\(bad)', which is not an interface name")
    exit(1)
}

try? FileManager.default.createDirectory(
    atPath: (dbPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)

// Held weakly inside the portal — keep strong refs for the process lifetime so returning from setup doesn't deallocate them.
final class Retainer: @unchecked Sendable {
    var manager: DownloadManager?
    var remote: RemoteAccess?
}
let retainer = Retainer()

Task {
    do {
        let store = try PersistenceStore(path: dbPath)
        let manager = DownloadManager(store: store)
        retainer.manager = manager
        await manager.restore()

        // The queue DB stores the portal token + password hash: keep it private on multi-user boxes (dir 0700, db + sidecars 0600).
        let dbDir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dbDir)
        for p in [dbPath, dbPath + "-wal", dbPath + "-shm"] where FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
        }

        var settings = await manager.currentSettings
        settings.remoteAccessEnabled = true
        settings.remotePort = port
        settings.remoteAllowLAN = allowLAN
        settings.remoteRequireAuth = requireAuth
        settings.remoteUsername = username
        settings.remoteReadOnly = false
        if !password.isEmpty { settings.remotePasswordHash = RemotePassword.hash(password) }
        if !tokenEnv.isEmpty { settings.remoteToken = tokenEnv }
        else if settings.remoteToken.isEmpty { settings.remoteToken = RemotePassword.randomHex(bytes: 24) }
        if !watchDir.isEmpty {
            settings.btWatchFolderPath = watchDir
            settings.btWatchFolderEnabled = true
            settings.btWatchStartWithoutConfirmation = watchAutoStart
        }
        if let aggregationEnv {
            settings.aggregationEnabled = ["1", "true", "yes", "on"].contains(aggregationEnv.lowercased())
        }
        // Empty-but-present means "every eligible interface"; unset means "leave the saved list alone".
        if aggregationAdaptersEnv != nil { settings.aggregationAdapterIds = aggregationAdapters }
        if let streams = Int(aggregationStreamsRaw) { settings.aggregationStreamsPerAdapter = streams }
        await manager.updateSettings(settings)
        _ = await manager.setDefaultSaveDirectory(saveDir)

        let remote = RemoteAccess()
        retainer.remote = remote
        await remote.apply(settings: settings, backend: manager)

        guard let bound = await remote.boundState() else {
            stderrLine("GoelDaemon: fatal — the portal failed to bind port \(port) (already in use, or a privileged port without permission)")
            exit(1)
        }
        let host = bound.exposedLAN ? "0.0.0.0" : "127.0.0.1"
        stderrLine("GoelDaemon: ready — portal on http://\(host):\(bound.port)  (user: \(username))")
        if bound.exposedLAN {
            stderrLine("GoelDaemon: WARNING — portal is on the LAN over plain HTTP; sign-in and token cross the network unencrypted. Use a trusted network or a TLS reverse proxy (e.g. nginx/caddy).")
        }
        stderrLine("GoelDaemon: save dir \(saveDir) · db \(dbPath)")
        // Never print the bearer token to stderr: it lands in the systemd journal and container log drivers.
        if tokenEnv.isEmpty {
            let tokenFile = (dbDir as NSString).appendingPathComponent("portal-token")
            #if canImport(Glibc)
            let prevMask = umask(0o077)
            #endif
            try? settings.remoteToken.write(toFile: tokenFile, atomically: true, encoding: .utf8)
            #if canImport(Glibc)
            umask(prevMask)
            #endif
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile)
            stderrLine("GoelDaemon: API token written to \(tokenFile) (mode 0600)")
        }
        if allowLAN && !bound.exposedLAN {
            stderrLine("GoelDaemon: NOTE — LAN access was requested but refused (no password set); bound 127.0.0.1 only. Set GOEL_PASSWORD to expose it.")
        }
    } catch {
        stderrLine("GoelDaemon: fatal: \(error)")
        exit(1)
    }
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

dispatchMain()
