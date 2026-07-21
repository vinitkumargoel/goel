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

    public static func jsonError(status: String, message: String) -> Data {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        return RemoteRouter.response(status: status, type: "application/json",
                                     body: Data("{\"ok\":false,\"error\":\"\(safe)\"}".utf8))
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
}

/// Stateful portal sessions + login lockout, owned by both I/O shells so auth
/// logic cannot drift between Network.framework and NIO.
public actor RemoteSessionStore {

    private var sessions: [String: Date] = [:]
    private var loginFailCount = 0
    private var loginLockUntil: Date?
    private var activeVerifications = 0
    private var passwordHash = ""
    private var sessionSeconds = 120 * 60
    private var username = ""

    public init() {}

    /// Adopt new credentials, optionally dropping every live session in the same
    /// actor hop. The two MUST be one call: split across two `await`s, the shell
    /// actor suspends in between and can service a login against the credentials
    /// it is halfway through rotating.
    public func configure(username: String, passwordHash: String, sessionMinutes: Int,
                          invalidatingSessions: Bool = false) {
        if invalidatingSessions { invalidateAll() }
        self.username = username
        self.passwordHash = passwordHash
        self.sessionSeconds = max(5, sessionMinutes) * 60
    }

    /// Drop all sessions (credential/token rotation).
    public func invalidateAll() {
        sessions.removeAll()
        loginFailCount = 0
        loginLockUntil = nil
    }

    public func validSession(_ request: RemoteRequest) -> Bool {
        guard let sid = request.cookie("goel_session"), let expiry = sessions[sid] else { return false }
        guard expiry > Date() else { sessions[sid] = nil; return false }
        return true
    }

    public func handleLogin(_ request: RemoteRequest) async -> Data {
        guard activeVerifications < RemoteAuthService.maxConcurrentVerifications else {
            return RemoteAuthService.jsonError(status: "429 Too Many Requests",
                                               message: "Server busy — try again in a moment.")
        }
        let creds = RemoteAuthService.parseCredentials(request)
        let userOK = RemoteRouter.constantTimeEquals(creds.username, username)
        let hash = passwordHash
        let password = creds.password
        let passOK: Bool
        if hash.isEmpty {
            passOK = false
        } else {
            activeVerifications += 1
            passOK = await Task.detached { RemotePassword.verify(password, against: hash) }.value
            activeVerifications -= 1
        }

        // Verify BEFORE lockout so a correct credential always signs in.
        if userOK && passOK {
            loginFailCount = 0
            loginLockUntil = nil
            pruneSessions()
            let sid = RemotePassword.randomHex(bytes: 32)
            sessions[sid] = Date().addingTimeInterval(TimeInterval(sessionSeconds))
            let cookie = "goel_session=\(sid); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(sessionSeconds)"
            return RemoteRouter.response(status: "200 OK", type: "application/json",
                                         body: Data("{\"ok\":true}".utf8),
                                         extraHeaders: ["Set-Cookie": cookie])
        }

        if let until = loginLockUntil, until > Date() {
            return RemoteAuthService.jsonError(status: "429 Too Many Requests",
                                               message: "Too many attempts — wait a moment and try again.")
        }
        loginFailCount += 1
        if loginFailCount >= 5 {
            loginLockUntil = Date().addingTimeInterval(30)
            loginFailCount = 0
        }
        let message = hash.isEmpty
            ? "No portal password is set yet — set one in the app under Settings → Web Access."
            : "Wrong username or password."
        return RemoteAuthService.jsonError(status: "401 Unauthorized", message: message)
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
