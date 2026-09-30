import Foundation

extension DownloadManager {

    struct InlineLogin: Equatable {
        var host: String
        var username: String
        var password: String
        var isTLS: Bool
    }

    /// Parses a link for the queue. `https://user:pass@host/…` loses its login in the parser (it would reach the
    /// database, exports and the portal verbatim), so the login moves to the per-host store the HTTP engine sends
    /// as Basic auth — over TLS only; a plain-http login is refused with a notice. `replaceExisting: false`
    /// never overwrites a login already saved for the host (links from feeds and pages); true is for the user's
    /// own word. Returns nil only when the line isn't a link at all.
    @discardableResult
    public func adoptInlineCredentials(_ raw: String, replaceExisting: Bool = false) -> DownloadSource? {
        guard let parsed = DownloadSource.parseWithCredentials(raw) else { return nil }
        guard parsed.authorization != nil, let login = Self.inlineLogin(in: raw) else { return parsed.source }
        guard login.isTLS else {
            postNotice(L10n.t("Didn’t save the login in the link for %@: Goel° only sends logins over HTTPS.",
                              login.host))
            return parsed.source
        }
        switch credentialStore.lookupCredential(forHost: login.host) {
        case .found(let user, let password) where user == login.username && password == login.password:
            return parsed.source
        case .found, .denied, .failed:
            // An unreadable entry is not "nothing saved": don't write over what may be there.
            guard replaceExisting else { return parsed.source }
        case .notFound:
            break
        }
        let write = credentialStore.storeCredential(username: login.username, password: login.password,
                                                    host: login.host)
        if !write.didStore {
            GoelLog.scheduler.error("Couldn’t save an inline login", .detail(write.statusDetail ?? ""))
            postNotice(L10n.t("Couldn’t save the login for %@ — the server may refuse the download.", login.host))
        }
        return parsed.source
    }

    /// Lowercased host: the store and the engine's lookup key on it, and DNS names are case-insensitive.
    static func inlineLogin(in raw: String) -> InlineLogin? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased(), !host.isEmpty,
              let user = comps.user, !user.isEmpty else { return nil }
        return InlineLogin(host: host, username: user, password: comps.password ?? "",
                           isTLS: scheme == "https")
    }
}
