import Foundation

/// Pure portal response / credential helpers shared by both remote-control shells.
public enum RemoteAuthService {

    public static let maxConcurrentVerifications = 2

    public static func redirect(to location: String) -> Data {
        RemoteRouter.response(status: "303 See Other", type: "text/plain",
                              body: Data(), extraHeaders: ["Location": location])
    }

    public static func htmlResponse(_ html: String) -> Data {
        RemoteRouter.response(status: "200 OK", type: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    public static func jsonError(status: String, message: String,
                                 extraHeaders: [String: String] = [:]) -> Data {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        return RemoteRouter.response(status: status, type: "application/json",
                                     body: Data("{\"ok\":false,\"error\":\"\(safe)\"}".utf8),
                                     extraHeaders: extraHeaders)
    }

    /// Accept credentials as JSON (portal login) or `x-www-form-urlencoded` (no-JS).
    public static func parseCredentials(_ request: RemoteRequest) -> (username: String, password: String) {
        struct Creds: Decodable { var username: String?; var password: String? }
        if let obj = try? JSONDecoder().decode(Creds.self, from: request.body) {
            return (obj.username ?? "", obj.password ?? "")
        }
        var username = "", password = ""
        for pair in String(decoding: request.body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            if kv[0] == "username" { username = value } else if kv[0] == "password" { password = value }
        }
        return (username, password)
    }

    public static func tokenAuthed(_ request: RemoteRequest, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if let header = request.headers["authorization"],
           RemoteRouter.constantTimeEquals(header, "Bearer \(token)") { return true }
        if let query = request.query["token"] { return RemoteRouter.constantTimeEquals(query, token) }
        return false
    }

    /// Whether a `…/?token=` deep-link landing on `/` should get a session cookie: the token authenticates
    /// only that page load, so `fetch`/`EventSource` 401'd. No weakening — rotating the token drops sessions.
    public static func shouldPromoteTokenToSession(_ request: RemoteRequest, requireAuth: Bool,
                                                   sessionAuthed: Bool, tokenAuthed: Bool) -> Bool {
        requireAuth && !sessionAuthed && tokenAuthed
            && request.method == "GET" && request.path == "/"
    }

    /// Identity asserted by a trusted upstream proxy, or nil — a bypass if wrong, so all four must hold:
    /// enabled, non-empty `trustedProxies`, kernel peer IP in it, plus a shared secret (loopback proves nothing).
    public static func trustedIdentity(_ request: RemoteRequest, client: String,
                                       policy: TrustedIdentityHeaderPolicy) -> String? {
        guard policy.isEnabled, !policy.trustedProxies.isEmpty else { return nil }
        guard !policy.sharedSecret.isEmpty,
              let presented = request.headers[TrustedIdentityHeaderPolicy.sharedSecretHeader],
              RemoteRouter.constantTimeEquals(presented, policy.sharedSecret) else { return nil }
        guard IPMatcher.matches(client, any: policy.trustedProxies) else { return nil }
        let header = policy.headerName.lowercased()
        guard !header.isEmpty,
              let raw = request.headers[header]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        // A header value with control characters is a smuggling attempt, not a
        // username. Refuse rather than sanitise.
        guard raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return raw
    }
}

// MARK: - Trusted upstream identity (header SSO)

/// Configuration for header-based single sign-on. Defaults to fully off.
public struct TrustedIdentityHeaderPolicy: Sendable, Equatable {
    /// Master switch. Off unless the operator explicitly enables it.
    public var isEnabled: Bool
    /// Header carrying the upstream-verified identity, e.g. `X-Forwarded-User`.
    public var headerName: String
    /// Literal IPs or IPv4 CIDR blocks allowed to assert that header.
    public var trustedProxies: [String]
    /// Secret the proxy must present in ``sharedSecretHeader``. Empty disables header SSO entirely: a
    /// peer address alone is no proof of origin when the proxy shares the host, as our docs deploy it.
    public var sharedSecret: String

    /// Header carrying ``sharedSecret``. Fixed, not configurable: the secret is the discriminator, not
    /// the name, and one less knob is one less way to misconfigure an authentication path.
    public static let sharedSecretHeader = "x-goel-proxy-secret"

    /// ``sharedSecret`` as the operator supplies it: launchd `EnvironmentVariables` or a `systemd`
    /// `EnvironmentFile`, never the settings JSON — that file is backed up and mailed to support.
    public static var secretFromEnvironment: String {
        ProcessInfo.processInfo.environment["GOEL_PORTAL_PROXY_SECRET"] ?? ""
    }

    public init(isEnabled: Bool = false, headerName: String = "X-Forwarded-User",
                trustedProxies: [String] = [], sharedSecret: String = "") {
        self.isEnabled = isEnabled
        self.headerName = headerName
        self.trustedProxies = trustedProxies
        self.sharedSecret = sharedSecret
    }

    /// Whether this policy can ever grant access. Used to log the "enabled but
    /// useless" misconfiguration loudly instead of failing closed in silence.
    public var isEffective: Bool { isEnabled && !trustedProxies.isEmpty && !sharedSecret.isEmpty }
}

/// Trusted-proxy address matching: exact text (covers IPv6/loopback without parsing them) + IPv4 CIDR.
/// Deliberately small — it decides *who may assert an identity*, so a subtle bug here is an auth bypass.
public enum IPMatcher {

    public static func matches(_ address: String, any patterns: [String]) -> Bool {
        let client = normalise(address)
        guard !client.isEmpty else { return false }
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("/") {
                if matchesCIDR(client, trimmed) { return true }
            } else if normalise(trimmed) == client {
                return true
            }
        }
        return false
    }

    /// Strip the decorations a socket API adds: `::ffff:10.0.0.1` (IPv4-mapped
    /// IPv6), a `%en0` scope id, and a trailing `:port`/`[…]` form.
    static func normalise(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespaces).lowercased()
        if let percent = value.firstIndex(of: "%") { value = String(value[value.startIndex..<percent]) }
        if value.hasPrefix("[") {
            // "[::1]:8899" → "::1"
            if let close = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<close])
            }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            // "10.0.0.1:53124" — a single colon can only be host:port here, since a
            // bare IPv6 address always has at least two.
            value = String(value[value.startIndex..<colon])
        }
        if value.hasPrefix("::ffff:") { value = String(value.dropFirst("::ffff:".count)) }
        return value
    }

    static func matchesCIDR(_ address: String, _ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let network = ipv4(String(parts[0])), let client = ipv4(address) else { return false }
        guard bits > 0 else { return true }
        let mask: UInt32 = bits == 32 ? .max : ~(UInt32.max >> UInt32(bits))
        return (network & mask) == (client & mask)
    }

    static func ipv4(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}

// MARK: - Per-client login throttle

/// Per-IP brute-force protection for the login route (global counting let one attacker lock everyone out).
/// After ``freeAttempts`` misses: ``baseDelay``, doubling to ``maxDelay``; a correct password clears it.
public struct RemoteLoginThrottle: Sendable, Equatable {

    /// The verdict for one login attempt.
    public enum Decision: Sendable, Equatable {
        case allowed
        /// Locked out; `retryAfter` seconds remain (rounded up, minimum 1).
        case blocked(retryAfter: Int)
    }

    /// Misses allowed before the backoff starts.
    public var freeAttempts: Int
    /// The first lockout, in seconds.
    public var baseDelay: TimeInterval
    /// Ceiling on the doubling.
    public var maxDelay: TimeInterval
    /// A quiet client is forgotten after this long, so a shared NAT address does
    /// not accumulate penalties forever.
    public var entryLifetime: TimeInterval
    /// Hard cap on tracked clients. Keys are real TCP peer addresses (not header-supplied), so growth
    /// is bounded by how fast an attacker can open sockets — the cap bounds it anyway.
    public var maxTrackedClients: Int

    private struct Entry: Equatable {
        var failures: Int
        var lockedUntil: Date?
        var lastSeen: Date
    }

    private var entries: [String: Entry] = [:]

    public init(freeAttempts: Int = 5, baseDelay: TimeInterval = 5,
                maxDelay: TimeInterval = 15 * 60, entryLifetime: TimeInterval = 60 * 60,
                maxTrackedClients: Int = 512) {
        self.freeAttempts = max(1, freeAttempts)
        self.baseDelay = max(1, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.entryLifetime = max(60, entryLifetime)
        self.maxTrackedClients = max(16, maxTrackedClients)
    }

    /// Build the policy from settings. Clients with no determinable address share the `"unknown"`
    /// bucket, which is strictly safer than exempting them.
    public init(settings: AppSettings) {
        self.init(freeAttempts: settings.remoteLoginMaxAttempts,
                  baseDelay: settings.remoteLoginBackoffSeconds)
    }

    /// May `client` attempt a login right now?
    public mutating func check(_ client: String, now: Date = Date()) -> Decision {
        let key = Self.bucket(client)
        guard let entry = entries[key], let until = entry.lockedUntil, until > now else {
            return .allowed
        }
        return .blocked(retryAfter: max(1, Int(until.timeIntervalSince(now).rounded(.up))))
    }

    /// Record a failed attempt and return the lockout it earned (0 while the
    /// client is still inside its free attempts).
    @discardableResult
    public mutating func recordFailure(_ client: String, now: Date = Date()) -> TimeInterval {
        let key = Self.bucket(client)
        expire(now: now)
        var entry = entries[key] ?? Entry(failures: 0, lockedUntil: nil, lastSeen: now)
        entry.failures += 1
        entry.lastSeen = now
        var penalty: TimeInterval = 0
        if entry.failures > freeAttempts {
            // 1st over-limit miss → baseDelay, 2nd → 2×, 3rd → 4×, capped.
            let steps = entry.failures - freeAttempts - 1
            penalty = min(maxDelay, baseDelay * pow(2, Double(min(steps, 20))))
            entry.lockedUntil = now.addingTimeInterval(penalty)
        }
        entries[key] = entry
        return penalty
    }

    /// A correct password: forget everything about this client.
    public mutating func recordSuccess(_ client: String) {
        entries[Self.bucket(client)] = nil
    }

    /// Drop every record (credential rotation, server restart).
    public mutating func reset() {
        entries.removeAll()
    }

    /// Take the tuning knobs from `other` but keep accumulated failure records: re-applying settings
    /// must not hand a locked-out attacker the clean slate a freshly-built throttle would.
    public mutating func adoptPolicy(of other: RemoteLoginThrottle) {
        freeAttempts = other.freeAttempts
        baseDelay = other.baseDelay
        maxDelay = other.maxDelay
        entryLifetime = other.entryLifetime
        maxTrackedClients = other.maxTrackedClients
    }

    /// Failure count currently held against a client — exposed for tests and for
    /// a future "who is knocking?" diagnostics view.
    public func failureCount(_ client: String) -> Int {
        entries[Self.bucket(client)]?.failures ?? 0
    }

    static func bucket(_ client: String) -> String {
        let normalised = IPMatcher.normalise(client)
        return normalised.isEmpty ? "unknown" : normalised
    }

    /// Forget quiet clients, then (if still over the cap) the least recently seen. Locked-out clients
    /// are kept preferentially: evicting them is what an attacker would want.
    private mutating func expire(now: Date) {
        entries = entries.filter { _, entry in
            if let until = entry.lockedUntil, until > now { return true }
            return now.timeIntervalSince(entry.lastSeen) < entryLifetime
        }
        guard entries.count > maxTrackedClients else { return }
        let sorted = entries.sorted { lhs, rhs in
            let lhsLocked = (lhs.value.lockedUntil ?? .distantPast) > now
            let rhsLocked = (rhs.value.lockedUntil ?? .distantPast) > now
            if lhsLocked != rhsLocked { return !lhsLocked }
            return lhs.value.lastSeen < rhs.value.lastSeen
        }
        for (key, _) in sorted.prefix(entries.count - maxTrackedClients) {
            entries[key] = nil
        }
    }
}

// MARK: - Portal security bundle

/// Everything the hardened portal needs beyond ``RemoteRouter/Config``, in one value so both I/O shells
/// (Network.framework, NIO) take the same parameter. Defaults = previous behaviour: no TLS, SSO off.
public struct RemotePortalSecurity: Sendable, Equatable {

    /// Per-IP login backoff.
    public var throttle: RemoteLoginThrottle
    /// Header-based SSO (off by default).
    public var sso: TrustedIdentityHeaderPolicy
    /// Serve HTTPS instead of HTTP.
    public var tlsEnabled: Bool
    /// Path to the PKCS#12 identity used when ``tlsEnabled``.
    public var tlsIdentityPath: String

    public init(throttle: RemoteLoginThrottle = RemoteLoginThrottle(),
                sso: TrustedIdentityHeaderPolicy = TrustedIdentityHeaderPolicy(),
                tlsEnabled: Bool = false, tlsIdentityPath: String = "") {
        self.throttle = throttle
        self.sso = sso
        self.tlsEnabled = tlsEnabled
        self.tlsIdentityPath = tlsIdentityPath
    }

    /// Map the user's (or the administrator's) settings onto the portal's
    /// security posture.
    public init(settings: AppSettings) {
        self.init(throttle: RemoteLoginThrottle(settings: settings),
                  sso: TrustedIdentityHeaderPolicy(
                      isEnabled: settings.remoteTrustedHeaderAuthEnabled,
                      headerName: settings.remoteTrustedHeaderName,
                      trustedProxies: settings.remoteTrustedProxies,
                      sharedSecret: TrustedIdentityHeaderPolicy.secretFromEnvironment),
                  tlsEnabled: settings.remoteTLSEnabled,
                  tlsIdentityPath: settings.remoteTLSIdentityPath)
    }

    /// Passphrase for ``tlsIdentityPath``, from the environment — deliberately **not** a setting: that
    /// JSON gets backed up and mailed to support. Use launchd `EnvironmentVariables` / `EnvironmentFile`.
    public static var tlsPassphrase: String {
        ProcessInfo.processInfo.environment["GOEL_PORTAL_TLS_PASSPHRASE"] ?? ""
    }
}

/// Stateful portal sessions + login lockout, owned by both I/O shells so auth
/// logic cannot drift between Network.framework and NIO.
public actor RemoteSessionStore {

    private var sessions: [String: Date] = [:]
    private var activeVerifications = 0
    private var passwordHash = ""
    private var sessionSeconds = 120 * 60
    private var username = ""

    /// Bumped whenever the credentials change. ``handleLogin`` suspends across PBKDF2 while this actor
    /// still services `configure`, so the epoch lets a resumed login notice its snapshot is stale.
    private var credentialEpoch = 0

    /// Per-client brute-force backoff. Replaces the old single global counter,
    /// which one attacker could trip to lock every other user out.
    private var throttle = RemoteLoginThrottle()

    public init() {}

    /// Adopt new credentials + optional session drop in ONE actor hop (two `await`s would let a login slip
    /// through); ``credentialEpoch`` catches in-flight ones. `sessionMinutes` clamped 5…43200: `*60` traps.
    public func configure(username: String, passwordHash: String, sessionMinutes: Int,
                          invalidatingSessions: Bool = false) {
        if invalidatingSessions { invalidateAll() }
        if invalidatingSessions || self.username != username || self.passwordHash != passwordHash {
            credentialEpoch &+= 1
        }
        self.username = username
        self.passwordHash = passwordHash
        self.sessionSeconds = min(max(5, sessionMinutes), 43_200) * 60
    }

    /// Adopt the login-throttle policy. Separate from ``configure`` because changing the backoff curve
    /// must not forgive currently locked-out clients: accumulated failure records are preserved.
    public func configure(throttle policy: RemoteLoginThrottle) {
        throttle.adoptPolicy(of: policy)
    }

    /// Drop all sessions (credential/token rotation).
    public func invalidateAll() {
        sessions.removeAll()
        throttle.reset()
    }

    public func validSession(_ request: RemoteRequest) -> Bool {
        guard let sid = request.cookie("goel_session"), let expiry = sessions[sid] else { return false }
        guard expiry > Date() else { sessions[sid] = nil; return false }
        return true
    }

    /// Verify a portal login for `client` (the socket's peer address from the I/O shell, never a header).
    /// The throttle is checked **before** the password, so a flood costs a lookup, not a PBKDF2 run each.
    public func handleLogin(_ request: RemoteRequest, client: String = "") async -> Data {
        let now = Date()
        if case .blocked(let retryAfter) = throttle.check(client, now: now) {
            return RemoteAuthService.jsonError(
                status: "429 Too Many Requests",
                message: "Too many sign-in attempts — try again in \(retryAfter)s.",
                extraHeaders: ["Retry-After": String(retryAfter)])
        }
        guard activeVerifications < RemoteAuthService.maxConcurrentVerifications else {
            return RemoteAuthService.jsonError(status: "429 Too Many Requests",
                                               message: "Server busy — try again in a moment.")
        }
        let creds = RemoteAuthService.parseCredentials(request)
        let userOK = RemoteRouter.constantTimeEquals(creds.username, username)
        let hash = passwordHash
        let epoch = credentialEpoch
        let password = creds.password
        let passOK: Bool
        if hash.isEmpty {
            passOK = false
        } else {
            activeVerifications += 1
            passOK = await Task.detached { RemotePassword.verify(password, against: hash) }.value
            activeVerifications -= 1
        }

        // `userOK`/`passOK` came from a snapshot taken before the verification suspended, and `configure`
        // can run during it: without this guard a revoked password could still mint a full-lifetime session.
        guard epoch == credentialEpoch else {
            return RemoteAuthService.jsonError(
                status: "401 Unauthorized",
                message: "Sign-in credentials changed while signing in — please try again.")
        }

        if userOK && passOK {
            throttle.recordSuccess(client)
            return RemoteRouter.response(status: "200 OK", type: "application/json",
                                         body: Data("{\"ok\":true}".utf8),
                                         extraHeaders: ["Set-Cookie": issueSession()])
        }

        let penalty = throttle.recordFailure(client, now: Date())
        if penalty > 0 {
            // Public fields only: the peer address is private under the logging rules, so this
            // records that a lockout happened and for how long, not who it hit.
            GoelLog.remote.notice("Portal login locked out after repeated failures",
                                  .duration(penalty, label: "lockoutSeconds"))
            return RemoteAuthService.jsonError(
                status: "429 Too Many Requests",
                message: "Too many sign-in attempts — try again in \(Int(penalty.rounded(.up)))s.",
                extraHeaders: ["Retry-After": String(Int(penalty.rounded(.up)))])
        }
        let message = hash.isEmpty
            ? "No portal password is set yet — set one in the app under Settings → Web Access."
            : "Wrong username or password."
        return RemoteAuthService.jsonError(status: "401 Unauthorized", message: message)
    }

    /// Failures currently held against a client. Test/diagnostics seam.
    public func loginFailures(for client: String) -> Int {
        throttle.failureCount(client)
    }

    /// Mint a session and return its `Set-Cookie`. Used by a password login and by an already-authenticated
    /// token deep-link — no password on that path, on purpose: the token *is* the credential.
    public func issueSession() -> String {
        pruneSessions()
        let sid = RemotePassword.randomHex(bytes: 32)
        sessions[sid] = Date().addingTimeInterval(TimeInterval(sessionSeconds))
        return "goel_session=\(sid); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(sessionSeconds)"
    }

    /// Clear the session cookie, reporting whether a live session was actually dropped — the caller
    /// only pays the generation bump (which winds down every open stream) for a real sign-out.
    public func handleLogout(_ request: RemoteRequest) -> (response: Data, droppedSession: Bool) {
        var dropped = false
        if let sid = request.cookie("goel_session") { dropped = sessions.removeValue(forKey: sid) != nil }
        let cookie = "goel_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        return (RemoteRouter.response(status: "200 OK", type: "application/json",
                                      body: Data("{\"ok\":true}".utf8),
                                      extraHeaders: ["Set-Cookie": cookie]), dropped)
    }

    private func pruneSessions() {
        let now = Date()
        sessions = sessions.filter { $0.value > now }
    }
}
