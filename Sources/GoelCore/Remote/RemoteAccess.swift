import Foundation

public enum RemotePortalStartFailure: Sendable, Equatable {
    case tlsIdentityUnavailable(path: String)
    case tlsUnsupported
    case portUnavailable(Int)
    case bindFailed(port: UInt16)

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

public enum RemoteAccessPolicy {
    public static func shouldRun(_ settings: AppSettings) -> Bool {
        settings.remoteAccessEnabled
    }

    /// Every live routing/auth field must be listed here, or a change to it stays inert until the next bind.
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
            || previous.remoteTLSEnabled != next.remoteTLSEnabled
            || previous.remoteTLSIdentityPath != next.remoteTLSIdentityPath
            || previous.remoteLoginMaxAttempts != next.remoteLoginMaxAttempts
            || previous.remoteLoginBackoffSeconds != next.remoteLoginBackoffSeconds
            || previous.remoteTrustedHeaderAuthEnabled != next.remoteTrustedHeaderAuthEnabled
            || previous.remoteTrustedHeaderName != next.remoteTrustedHeaderName
            || previous.remoteTrustedProxies != next.remoteTrustedProxies
    }
}

public actor RemoteAccess {

    private var server: RemoteControlServer?
    private var applied: AppSettings?
    private var running = false
    private var failure: RemotePortalStartFailure?

    public init() {}

    public func apply(settings: AppSettings, backend: RemoteBackend) async {
        guard RemoteAccessPolicy.shouldRun(settings) else {
            await stop()
            return
        }
        if let applied, running, !RemoteAccessPolicy.needsRestart(previous: applied, next: settings) {
            return
        }
        // `exactly:` not `clamping:`: an out-of-range port is a typo, and clamping it to 0 makes Network.framework bind any free port.
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
            // Leave `applied` nil so an identical apply retries, and keep the reason so the UI can say what went wrong.
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
        // Drop the server so a later apply with a different backend rebuilds the weakly-held manager pointer.
        server = nil
        applied = nil
        running = false
        failure = nil
    }

    public var isRunning: Bool { running }

    public var lastStartFailure: RemotePortalStartFailure? { failure }

    public func boundState() async -> (port: UInt16, exposedLAN: Bool)? {
        await server?.boundState()
    }
}
