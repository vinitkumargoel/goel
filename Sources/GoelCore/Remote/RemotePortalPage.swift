import Foundation

/// The two HTML documents the portal serves: the control app at `/` and the
/// sign-in form at `/login`.
///
/// Both are thin shells. The UI itself — markup, styling, behaviour — is a React
/// application under `/portal`, compiled into ``PortalBundle`` and served from
/// `/assets/` under content-addressed names. What stays here is only what the
/// server alone knows: which theme to start from, who is signed in, whether the
/// session is read-only, and any login error to display.
///
/// The portal ships the **same four named themes as the desktop app** (Frost
/// Light, Frost Dark, Dracula, Nord). They are defined once, in
/// `portal/src/styles/themes.css`, and reach both documents through the bundle —
/// there is deliberately no second copy in Swift to fall out of step. The active
/// theme is chosen per-browser (persisted in `localStorage`), defaulting to the
/// server's `remoteTheme`, so the web look is independent of the desktop's.
extension RemoteRouter {

    /// The full control portal. Auth is by session cookie (or `?token=` for
    /// scripts); the page embeds no secret. A small `BOOT` object seeds the
    /// default theme, the signed-in username, and read-only state so the app can
    /// paint without first round-tripping to `/api/config`.
    ///
    /// `BOOT` is a JSON literal rather than a `data-` attribute because it
    /// carries three types; `bootJSON(config:)` neutralises `<` so a username
    /// can never close the `<script>` element.
    static func page(config: Config) -> String {
        let boot = bootJSON(config: config)
        let theme = AppThemeToken.sanitize(config.theme)
        return #"""
        <!doctype html><html lang="en" data-theme="\#(theme)"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Goel° — Web Portal</title>
        <link rel="icon" type="image/svg+xml" href="\#(faviconDataURI)">
        <link rel="stylesheet" href="\#(PortalBundle.cssPath)">
        </head>
        <body>
        <div id="root"></div>
        <script id="goel-boot" type="application/json">\#(boot)</script>
        <script type="module" src="\#(PortalBundle.jsPath)"></script>
        </body></html>
        """#
    }

    /// The login page (served at `/login`). A minimal themed form that POSTs
    /// JSON credentials to `/login`; on success the server sets the session
    /// cookie and the page redirects to `/`.
    ///
    /// Deliberately not React: it is one form shown before anyone is signed in,
    /// and making it wait on the 233 kB app bundle would slow down the first
    /// screen every user meets.
    static func loginPage(theme: String, error: String?) -> String {
        let themeAttr = AppThemeToken.sanitize(theme)
        let errHTML = error.map { #"<div class="err">\#(htmlEscape($0))</div>"# } ?? ""
        return #"""
        <!doctype html><html lang="en" data-theme="\#(themeAttr)"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Goel° — Sign in</title>
        <link rel="icon" type="image/svg+xml" href="\#(faviconDataURI)">
        <link rel="stylesheet" href="\#(PortalBundle.loginCSSPath)">
        </head><body>
        <form class="card" id="f" autocomplete="on">
          <div class="brand"><span class="mk">\#(logoSVG)</span><h1>Goel° Web</h1><div class="sub">Sign in to control your downloads</div></div>
          \#(errHTML)
          <div class="fld"><label>Username</label><input id="u" name="username" autocomplete="username" autofocus></div>
          <div class="fld"><label>Password</label><input id="p" name="password" type="password" autocomplete="current-password"></div>
          <button type="submit">Sign in</button>
          <div class="foot">Goel° download manager<br><span class="warn">⚠</span> Plain HTTP — use only on a trusted network or behind TLS.</div>
        </form>
        <script src="\#(PortalBundle.loginJSPath)"></script>
        </body></html>
        """#
    }

    // MARK: Bootstrap

    private static func bootJSON(config: Config) -> String {
        let theme = AppThemeToken.sanitize(config.theme)
        // JSON, with `<` neutralised so a username can't break out of <script>.
        let obj: [String: Any] = [
            "theme": theme,
            "username": config.username,
            "readOnly": config.readOnly,
            "requireAuth": config.requireAuth,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Brand assets

    static let logoSVG = ##"<svg viewBox="0 0 48 48"><defs><linearGradient id="lg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5db4f5"/><stop offset="1" stop-color="#2f83e6"/></linearGradient></defs><rect width="48" height="48" rx="10.8" fill="url(#lg)"/><g stroke="#fff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round" fill="none"><circle cx="24" cy="21" r="8.5"/><path d="M32.5 12.5 L32.5 32 Q32.5 36 27 36"/></g><circle cx="38.2" cy="11" r="3.1" fill="#fff"/></svg>"##

    static let faviconDataURI = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'%3E%3Cdefs%3E%3ClinearGradient id='s' x1='0' y1='0' x2='0' y2='1'%3E%3Cstop offset='0' stop-color='%235db4f5'/%3E%3Cstop offset='1' stop-color='%232f83e6'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='48' height='48' rx='10.8' fill='url(%23s)'/%3E%3Cg stroke='%23fff' stroke-width='3.4' stroke-linecap='round' stroke-linejoin='round' fill='none'%3E%3Ccircle cx='24' cy='21' r='8.5'/%3E%3Cpath d='M32.5 12.5 L32.5 32 Q32.5 36 27 36'/%3E%3C/g%3E%3Ccircle cx='38.2' cy='11' r='3.1' fill='%23fff'/%3E%3C/svg%3E"
}

/// A tiny, dependency-free sanitizer for the theme token embedded into the page,
/// so a corrupt/unknown persisted value can never inject markup or select a
/// missing theme. Kept in Core (the app's `AppTheme` lives in the app layer).
enum AppThemeToken {
    static let known: Set<String> = ["frost-light", "frost-dark", "dracula", "nord"]
    static func sanitize(_ token: String) -> String {
        known.contains(token) ? token : "frost-dark"
    }
}
