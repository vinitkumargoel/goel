import Foundation
import GoelCore

// ============================================================================
// GoelDaemon — the headless Linux entry point.
//
// On macOS the SwiftUI app owns the DownloadManager and (optionally) exposes the
// web portal. On Linux there is no desktop shell, so the portal IS the UI: this
// daemon boots the same GoelCore DownloadManager and turns the remote-control
// server on unconditionally, reading its configuration from the environment.
//
//   GOEL_PORT          portal port                        (default 8080)
//   GOEL_ALLOW_LAN     bind 0.0.0.0 vs 127.0.0.1          (default true)
//   GOEL_REQUIRE_AUTH  require sign-in                    (default true)
//   GOEL_USERNAME      portal username                    (default "admin")
//   GOEL_PASSWORD      portal password (plaintext, hashed at boot)
//   GOEL_SAVE_DIR      default download folder            (default ~/Downloads)
//   GOEL_DB            queue database path                (default ~/.local/share/goel-downloader/queue.sqlite)
// ============================================================================

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
// Safe default: loopback-only unless the operator explicitly opts into LAN (and
// sets a password — the server refuses a passwordless LAN bind regardless).
let allowLAN = envBool("GOEL_ALLOW_LAN", false)
let requireAuth = envBool("GOEL_REQUIRE_AUTH", true)
let username = env("GOEL_USERNAME", "admin")
let password = ProcessInfo.processInfo.environment["GOEL_PASSWORD"] ?? ""
let saveDir = env("GOEL_SAVE_DIR", home.appendingPathComponent("Downloads").path)

try? FileManager.default.createDirectory(
    atPath: (dbPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)

// The server holds `manager` weakly, and both are built inside the async task
// below; without a strong process-lifetime reference they'd be deallocated the
// moment setup returns, leaving the portal with a nil backend ("Shutting down").
final class Retainer: @unchecked Sendable {
    var manager: DownloadManager?
    var server: RemoteControlServer?
}
let retainer = Retainer()

Task {
    do {
        let store = try PersistenceStore(path: dbPath)
        let manager = DownloadManager(store: store)
        retainer.manager = manager   // keep alive for the process lifetime
        await manager.restore()

        // The queue DB stores the portal token + password hash; keep it private on
        // multi-user Linux boxes (dir 0700, db + WAL/SHM sidecars 0600).
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
        if settings.remoteToken.isEmpty { settings.remoteToken = RemotePassword.randomHex(bytes: 24) }
        await manager.updateSettings(settings)
        _ = await manager.setDefaultSaveDirectory(saveDir)

        let server = RemoteControlServer(manager: manager)
        retainer.server = server
        let config = RemoteRouter.Config(
            token: settings.remoteToken, requireAuth: settings.remoteRequireAuth,
            readOnly: settings.remoteReadOnly, theme: settings.remoteTheme,
            username: settings.remoteUsername)
        await server.start(
            port: UInt16(clamping: port), allowLAN: allowLAN, config: config,
            passwordHash: settings.remotePasswordHash, sessionMinutes: settings.remoteSessionMinutes)

        // Report the ACTUAL bound state — never claim "ready" if the bind failed,
        // and derive loopback-vs-LAN from what the server really did (not a
        // re-computed guess that can drift from the bind decision).
        guard let bound = await server.boundState() else {
            stderrLine("GoelDaemon: fatal — the portal failed to bind port \(port) (already in use, or a privileged port without permission)")
            exit(1)
        }
        let host = bound.exposedLAN ? "0.0.0.0" : "127.0.0.1"
        stderrLine("GoelDaemon: ready — portal on http://\(host):\(bound.port)  (user: \(username))")
        stderrLine("GoelDaemon: save dir \(saveDir) · db \(dbPath)")
        stderrLine("GoelDaemon: API token \(settings.remoteToken)")
        if allowLAN && !bound.exposedLAN {
            stderrLine("GoelDaemon: NOTE — LAN access was requested but refused (no password set); bound 127.0.0.1 only. Set GOEL_PASSWORD to expose it.")
        }
    } catch {
        stderrLine("GoelDaemon: fatal: \(error)")
        exit(1)
    }
}

// Clean shutdown on Ctrl-C / systemd stop.
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

// Keep the process alive; the NIO event loop and the manager run on their own
// threads / the cooperative pool.
dispatchMain()
