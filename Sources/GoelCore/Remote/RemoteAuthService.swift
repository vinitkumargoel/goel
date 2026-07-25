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

    /// The identity asserted by a trusted upstream proxy, or `nil`.
    ///
    /// This is the cheap 90% of "enterprise SSO": Cloudflare Access, Authelia,
    /// oauth2-proxy and most ingress controllers all authenticate the user
    /// themselves and then forward the result in a header. Honouring that header
    /// gets SAML/OIDC-backed sign-in for the portal without implementing either
    /// protocol.
    ///
    /// It is also, if you get it wrong, a total authentication bypass — anyone who
    /// can reach the port just sends the header. Four things guard it, and all
    /// four must hold:
    ///
    /// 1. The operator turned it on (``TrustedIdentityHeaderPolicy/isEnabled``).
    /// 2. ``TrustedIdentityHeaderPolicy/trustedProxies`` is non-empty — an empty
    ///    list means "trust nobody", never "trust everybody".
    /// 3. The connection's *socket* peer address is in that list. The peer address
    ///    comes from the kernel, not from a header, so it cannot be spoofed by the
    ///    client; `X-Forwarded-For` is deliberately not consulted for this.
    /// 4. The request carries ``TrustedIdentityHeaderPolicy/sharedSecretHeader``
    ///    matching ``TrustedIdentityHeaderPolicy/sharedSecret``, which is never
    ///    empty when the feature is live.
    ///
    /// Rule 4 exists because rule 3 only discriminates when the proxy is on a
    /// *different* host, and the deployment we actually ship docs for is the
    /// opposite: portal bound to loopback with nginx/Authelia in front of it on the
    /// same box. There the proxy's peer address is `127.0.0.1` — indistinguishable
    /// from every other process on the machine, so any local user could `curl` the
    /// header in and become whoever they liked. A secret the proxy holds and other
    /// local processes do not is what restores the discriminator. It is compared in
    /// constant time, and it lives in the environment rather than in settings for
    /// the same reason as ``RemotePortalSecurity/tlsPassphrase``.
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
    /// Secret the proxy must present in ``sharedSecretHeader``. Empty disables
    /// header SSO entirely — a peer address alone is not proof of proxy origin
    /// when the proxy shares the host with everyone else, which is the deployment
    /// we document.
    public var sharedSecret: String

    /// Header carrying ``sharedSecret``. Fixed rather than configurable: the name
    /// is not the discriminator, the secret is, and one less knob is one less way
    /// to misconfigure an authentication path.
    public static let sharedSecretHeader = "x-goel-proxy-secret"

    /// ``sharedSecret`` as the operator supplies it: a launchd
    /// `EnvironmentVariables` entry or a `systemd` `EnvironmentFile`, never the
    /// settings JSON — that file gets backed up, exported and attached to support
    /// emails, and this value is a credential.
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

/// Minimal address matching for the trusted-proxy list: exact text match (which
/// covers IPv6 and loopback without pretending to parse them) plus IPv4 CIDR.
///
/// Deliberately small. This decides *who may assert an identity*, so a subtle
/// bug here is an auth bypass; a matcher you can read in one sitting is worth
/// more than one that understands every address form.
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

/// Per-IP brute-force protection for the portal's login route.
///
/// The portal used to count failures *globally*, which meant two things, both
/// bad: an attacker hammering from one address locked the legitimate user out
/// (a trivial denial of service), and the fixed 30-second penalty was cheap
/// enough that an online guess against a weak password stayed practical.
///
/// This tracks failures per client address and applies exponential backoff:
/// after ``freeAttempts`` misses the client is locked out for ``baseDelay``,
/// doubling on every further miss up to ``maxDelay``. A correct password clears
/// the client's record immediately, so a user who fat-fingers their password
/// twice and then gets it right is never penalised.
///
/// It is a value type driven by an injected `now`, so the backoff curve can be
/// tested deterministically instead of with `sleep`.
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
    /// Hard cap on tracked clients. The keys are real TCP peer addresses (not
    /// header-supplied), so this can only grow as fast as an attacker can open
    /// sockets — but a cap keeps that bounded anyway.
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

    /// Build the policy from settings. Clients whose address could not be
    /// determined share the `"unknown"` bucket, which is strictly safer than
    /// exempting them.
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

    /// Take the tuning knobs from `other` while keeping this throttle's accumulated
    /// failure records. Re-applying settings must not hand a locked-out attacker a
    /// clean slate — which is exactly what assigning a freshly-built throttle would.
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

    /// Forget quiet clients, then — if still over the cap — the least recently
    /// seen. Locked-out clients are kept preferentially: evicting them is what an
    /// attacker would want.
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

/// Everything the hardened portal needs beyond the routing ``RemoteRouter/Config``.
///
/// Bundled into one value so the two I/O shells (Network.framework and NIO) take
/// the same parameter, and so ``RemoteAccess`` has exactly one thing to build
/// from settings. Defaults reproduce the portal's previous behaviour exactly: no
/// TLS, header SSO off, and a throttle whose free-attempt count matches the old
/// fixed lockout threshold.
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

    /// The passphrase for ``tlsIdentityPath``, taken from the environment.
    ///
    /// Deliberately **not** a setting: the settings file is plain JSON that gets
    /// backed up, exported and attached to support emails. A launchd
    /// `EnvironmentVariables` entry (or a `systemd` `EnvironmentFile` on Linux)
    /// keeps the passphrase in the place an operator already secures.
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

    /// Bumped every time the credentials this store authenticates against change.
    ///
    /// ``handleLogin`` suspends for the whole PBKDF2 verification, and this actor
    /// happily services ``configure(username:passwordHash:sessionMinutes:invalidatingSessions:)``
    /// during that hop. The epoch is the token that lets the resumed login notice
    /// it is holding a snapshot of credentials that no longer exist.
    private var credentialEpoch = 0

    /// Per-client brute-force backoff. Replaces the old single global counter,
    /// which one attacker could trip to lock every other user out.
    private var throttle = RemoteLoginThrottle()

    public init() {}

    /// Adopt new credentials, optionally dropping every live session in the same
    /// actor hop. The two MUST be one call: split across two `await`s, the shell
    /// actor suspends in between and can service a login against the credentials
    /// it is halfway through rotating.
    ///
    /// Being one hop is necessary but not sufficient: a login that is *already*
    /// suspended inside its PBKDF2 verification resumes after this returns, so it
    /// also has to be told the ground moved. Bumping ``credentialEpoch`` is that
    /// signal — see the guard in ``handleLogin(_:client:)``. The epoch only moves
    /// when the credential material actually changes (or the caller is dropping
    /// sessions anyway), so an unrelated settings save cannot fail a login that
    /// happens to be in flight.
    public func configure(username: String, passwordHash: String, sessionMinutes: Int,
                          invalidatingSessions: Bool = false) {
        if invalidatingSessions { invalidateAll() }
        if invalidatingSessions || self.username != username || self.passwordHash != passwordHash {
            credentialEpoch &+= 1
        }
        self.username = username
        self.passwordHash = passwordHash
        self.sessionSeconds = max(5, sessionMinutes) * 60
    }

    /// Adopt the login-throttle policy. Kept separate from ``configure`` because
    /// changing the backoff curve must not silently forgive clients that are
    /// currently locked out — the accumulated failure records are preserved.
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

    /// Verify a portal login for the client at `client` (the socket's peer
    /// address, supplied by the I/O shell — never a header).
    ///
    /// The throttle is consulted **before** the password is verified, which
    /// reverses the earlier "verify first so a correct credential always works"
    /// ordering. That ordering only made sense while the lockout was global: a
    /// user could be locked out by someone else's guessing, so refusing them
    /// outright was unacceptable. Now the penalty follows the guessing address,
    /// and checking first is what makes the throttle worth having — it means a
    /// flood costs an attacker a dictionary lookup instead of a PBKDF2 run each.
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

        // `userOK`/`passOK` were decided against a snapshot taken *before* the
        // verification suspended, and this actor services `configure` during that
        // suspension. Without this guard an admin rotating a leaked password would
        // see `invalidateAll()` run and then have an in-flight login mint a brand
        // new session for the password they just revoked — good for the full
        // session lifetime. Refuse; the client can retry against the live
        // credentials. No failure is recorded: the attempt was never judged.
        guard epoch == credentialEpoch else {
            return RemoteAuthService.jsonError(
                status: "401 Unauthorized",
                message: "Sign-in credentials changed while signing in — please try again.")
        }

        if userOK && passOK {
            throttle.recordSuccess(client)
            pruneSessions()
            let sid = RemotePassword.randomHex(bytes: 32)
            sessions[sid] = Date().addingTimeInterval(TimeInterval(sessionSeconds))
            let cookie = "goel_session=\(sid); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(sessionSeconds)"
            return RemoteRouter.response(status: "200 OK", type: "application/json",
                                         body: Data("{\"ok\":true}".utf8),
                                         extraHeaders: ["Set-Cookie": cookie])
        }

        let penalty = throttle.recordFailure(client, now: Date())
        if penalty > 0 {
            // Public fields only: the peer address is private data under the
            // logging rules, so the line records that a lockout happened and for
            // how long, not who it hit.
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

    /// Clear session cookie. Caller must bump generation so open SSE/streams re-auth.
    public func handleLogout(_ request: RemoteRequest) -> Data {
        if let sid = request.cookie("goel_session") { sessions[sid] = nil }
        let cookie = "goel_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        return RemoteRouter.response(status: "200 OK", type: "application/json",
                                     body: Data("{\"ok\":true}".utf8),
                                     extraHeaders: ["Set-Cookie": cookie])
    }

    private func pruneSessions() {
        let now = Date()
        sessions = sessions.filter { $0.value > now }
    }
}
