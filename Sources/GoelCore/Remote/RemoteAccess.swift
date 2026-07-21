import Foundation

/// Pure restart / run decisions for the remote portal, lifted out of the
/// lifecycle actor so they can be unit-tested with plain `AppSettings` values.
public enum RemoteAccessPolicy {

    /// Whether settings want the portal listening at all.
    public static func shouldRun(_ settings: AppSettings) -> Bool {
        settings.remoteAccessEnabled
    }

    /// Whether an already-running portal must be reconfigured for `next`.
    /// Covers bind (port/LAN) and every live routing/auth field the server
    /// applies on `start` — theme, read-only, session length included, matching
    /// the previous AppViewModel snapshot comparison.
    public static func needsRestart(previous: AppSettings, next: AppSettings) -> Bool {
        previous.remotePort != next.remotePort
            || previous.remoteAllowLAN != next.remoteAllowLAN
            || previous.remoteToken != next.remoteToken
            || previous.remoteRequireAuth != next.remoteRequireAuth
            || previous.remoteUsername != next.remoteUsername
            || previous.remotePasswordHash != next.remotePasswordHash
            || previous.remoteReadOnly != next.remoteReadOnly
            || previous.remoteTheme != next.remoteTheme
            || previous.remoteSessionMinutes != next.remoteSessionMinutes
    }
}

/// Deep façade: start/stop/restart the remote portal from `AppSettings` + backend.
///
/// Hides the platform `RemoteControlServer` (Network.framework / NIO) and the
/// "did settings change enough to re-apply?" comparison. Callers just hand
/// current settings on every change; the actor decides stop / start / no-op.
public actor RemoteAccess {

    private var server: RemoteControlServer?
    /// Last settings we applied while enabled (nil when stopped / never started).
    private var applied: AppSettings?
    private var running = false

    public init() {}

    /// Apply desired settings: if remote disabled → stop; if enabled → start or
    /// reconfigure when bind/auth/token (or other live config) changed.
    public func apply(settings: AppSettings, backend: RemoteBackend) async {
        guard RemoteAccessPolicy.shouldRun(settings) else {
            await stop()
            return
        }
        if let applied, running, !RemoteAccessPolicy.needsRestart(previous: applied, next: settings) {
            return
        }
        let server = self.server ?? RemoteControlServer(manager: backend)
        self.server = server
        let config = RemoteRouter.Config(
            token: settings.remoteToken,
            requireAuth: settings.remoteRequireAuth,
            readOnly: settings.remoteReadOnly,
            theme: settings.remoteTheme,
            username: settings.remoteUsername)
        await server.start(
            port: UInt16(clamping: settings.remotePort),
            allowLAN: settings.remoteAllowLAN,
            config: config,
            passwordHash: settings.remotePasswordHash,
            sessionMinutes: settings.remoteSessionMinutes)
        self.applied = settings
        self.running = true
    }

    public func stop() async {
        guard server != nil || running else {
            applied = nil
            running = false
            return
        }
        await server?.stop()
        applied = nil
        running = false
    }

    public var isRunning: Bool { running }
}
