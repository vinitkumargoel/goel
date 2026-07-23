import Foundation
import GoelContracts
import GoelCore

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
    /// Last settings we successfully bound with (nil when stopped / bind failed).
    private var applied: AppSettings?
    private var running = false

    public init() {}

    /// Apply desired settings: if remote disabled → stop; if enabled → start or
    /// reconfigure when bind/auth/token (or other live config) changed.
    ///
    /// `isRunning` / `applied` only advance when the server actually has a bound
    /// listener — a failed bind leaves us stopped so a later identical apply retries.
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
        if await server.boundState() != nil {
            self.applied = settings
            self.running = true
        } else {
            // Bind failed (port in use, privilege, …). Do not claim success — leave
            // `applied` nil so the next apply with the same settings retries.
            self.applied = nil
            self.running = false
        }
    }

    public func stop() async {
        guard server != nil || running else {
            applied = nil
            running = false
            return
        }
        await server?.stop()
        // Drop the server so a later apply with a different backend rebuilds
        // the weak manager pointer (RemoteControlServer holds backend weakly).
        server = nil
        applied = nil
        running = false
    }

    public var isRunning: Bool { running }

    /// Bound port / LAN exposure from the live server, if any.
    public func boundState() async -> (port: UInt16, exposedLAN: Bool)? {
        await server?.boundState()
    }
}
