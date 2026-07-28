import Foundation

/// Why the last portal start left nothing listening, or nil when bound / stopped on purpose. The three fail-closed
/// refusals were silent, so Settings offered "Open" for a portal that was never there; both transports report these.
public enum RemotePortalStartFailure: Sendable, Equatable {
    /// Portal TLS is on, but the PKCS#12 identity at this path could not be loaded: wrong path, unreadable
    /// file, or a `GOEL_PORTAL_TLS_PASSPHRASE` that doesn't match the bundle.
    case tlsIdentityUnavailable(path: String)
    /// Portal TLS is on, but this build cannot terminate it — the Linux daemon links SwiftNIO without NIOSSL.
    /// Separate case because the fix differs: a TLS-terminating reverse proxy, not a certificate path.
    case tlsUnsupported
    /// The configured port is outside 1…65535, so there is nothing to bind.
    case portUnavailable(Int)
    /// The socket could not be bound — usually the port is already taken by
    /// another process.
    case bindFailed(port: UInt16)

    /// Plain-language text written for the person using the app, naming the fix.
    /// Matches the wording style of ``SFTPError/message``.
    public var message: String {
        switch self {
        case .tlsIdentityUnavailable(let path):
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = trimmed.isEmpty ? "No HTTPS certificate is set, so web access can't start."
                                          : "The HTTPS certificate at “\(trimmed)” couldn't be opened, so web access can't start."
            return "\(subject) Check the path, and that GOEL_PORTAL_TLS_PASSPHRASE is set to that certificate's passphrase. Web access stays off rather than serving unencrypted."
        case .tlsUnsupported:
            return "This build can't serve HTTPS itself, so web access stays off rather than serving unencrypted. Put it behind a TLS-terminating reverse proxy (nginx, Caddy, Traefik) and turn “Serve over HTTPS” off."
        case .portUnavailable(let port):
            return "\(port) isn't a usable port, so web access can't start. Pick a number between 1 and 65535 — 8899 is the default."
        case .bindFailed(let port):
            return "Web access couldn't open port \(port) — another app is probably already using it. Pick a different port and try again."
        }
    }
}

/// Pure restart / run decisions for the remote portal, lifted out of the
/// lifecycle actor so they can be unit-tested with plain `AppSettings` values.
public enum RemoteAccessPolicy {

    /// Whether settings want the portal listening at all.
    public static func shouldRun(_ settings: AppSettings) -> Bool {
        settings.remoteAccessEnabled
    }

    /// Whether an already-running portal must be reconfigured for `next`. Covers bind (port/LAN) and every live
    /// routing/auth field applied on `start` — theme, read-only, session length included.
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
            // Portal hardening is applied once at `start`, so any change to it
            // has to re-bind or the new policy stays inert.
            || previous.remoteTLSEnabled != next.remoteTLSEnabled
            || previous.remoteTLSIdentityPath != next.remoteTLSIdentityPath
            || previous.remoteLoginMaxAttempts != next.remoteLoginMaxAttempts
            || previous.remoteLoginBackoffSeconds != next.remoteLoginBackoffSeconds
            || previous.remoteTrustedHeaderAuthEnabled != next.remoteTrustedHeaderAuthEnabled
            || previous.remoteTrustedHeaderName != next.remoteTrustedHeaderName
            || previous.remoteTrustedProxies != next.remoteTrustedProxies
    }
}

/// Deep façade: start/stop/restart the remote portal from `AppSettings` + backend. Hides the platform
/// `RemoteControlServer` (Network.framework / NIO); callers hand it settings and it decides stop / start / no-op.
public actor RemoteAccess {

    private var server: RemoteControlServer?
    /// Last settings we successfully bound with (nil when stopped / bind failed).
    private var applied: AppSettings?
    private var running = false
    /// Why the last apply left nothing listening. Cleared on every success and on
    /// a deliberate stop.
    private var failure: RemotePortalStartFailure?

    public init() {}

    /// Apply desired settings: disabled → stop; enabled → start or reconfigure when live config changed. `isRunning` /
    /// `applied` advance only on a genuinely bound listener — a failed bind leaves us stopped so an identical apply retries.
    public func apply(settings: AppSettings, backend: RemoteBackend) async {
        guard RemoteAccessPolicy.shouldRun(settings) else {
            await stop()
            return
        }
        if let applied, running, !RemoteAccessPolicy.needsRestart(previous: applied, next: settings) {
            return
        }
        // A port outside 1…65535 is a typo, not a request for an ephemeral bind: `UInt16(clamping:)` mapped it to 0,
        // which Network.framework reads as "any free port", binding somewhere nobody could predict.
        guard let port = UInt16(exactly: settings.remotePort), port > 0 else {
            GoelLog.remote.error("Web access port is out of range",
                                 .count(settings.remotePort, label: "port"))
            await stop()
            failure = .portUnavailable(settings.remotePort)
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
            port: port,
            allowLAN: settings.remoteAllowLAN,
            config: config,
            passwordHash: settings.remotePasswordHash,
            sessionMinutes: settings.remoteSessionMinutes,
            security: RemotePortalSecurity(settings: settings))
        if await server.boundState() != nil {
            self.applied = settings
            self.running = true
            self.failure = nil
        } else {
            // Bind failed (port in use, privilege, …). Leave `applied` nil so an identical apply retries, and keep
            // the reason so the UI can say what went wrong instead of showing a portal that isn't there.
            self.applied = nil
            self.running = false
            self.failure = await server.lastStartFailure()
        }
    }

    public func stop() async {
        guard server != nil || running else {
            applied = nil
            running = false
            failure = nil
            return
        }
        await server?.stop()
        // Drop the server so a later apply with a different backend rebuilds
        // the weak manager pointer (RemoteControlServer holds backend weakly).
        server = nil
        applied = nil
        running = false
        failure = nil
    }

    public var isRunning: Bool { running }

    /// Why web access is off after the last ``apply(settings:backend:)``, or nil when running / stopped on purpose.
    /// Companion to ``isRunning``: that says *whether*, this says *why not*, in words a person can act on.
    public var lastStartFailure: RemotePortalStartFailure? { failure }

    /// Bound port / LAN exposure from the live server, if any.
    public func boundState() async -> (port: UInt16, exposedLAN: Bool)? {
        await server?.boundState()
    }
}
