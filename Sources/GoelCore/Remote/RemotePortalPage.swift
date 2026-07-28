import Foundation

extension RemoteRouter {

    /// Auth is by session cookie (or `?token=` for scripts) — this page must embed no secret.
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

    /// `login.js` is served as a static asset outside the Vite bundle, so it cannot import the
    /// portal's translations. Its three failure messages ride along as `data-` attributes
    /// instead — escaped like any other value, since a translation may contain `"` or `<`.
    static func loginPage(theme: String, error: String?) -> String {
        let themeAttr = AppThemeToken.sanitize(theme)
        let errHTML = error.map { #"<div class="err">\#(htmlEscape($0))</div>"# } ?? ""
        let failed = htmlEscape(L10n.t("Sign-in failed"))
        let credentials = htmlEscape(L10n.t("Wrong username or password"))
        let offline = htmlEscape(L10n.t("Could not reach the server"))
        return #"""
        <!doctype html><html lang="\#(L10n.languageCode(for: L10n.currentLanguage))" data-theme="\#(themeAttr)"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(htmlEscape(L10n.t("Goel° — Sign in")))</title>
        <link rel="icon" type="image/svg+xml" href="\#(faviconDataURI)">
        <link rel="stylesheet" href="\#(PortalBundle.loginCSSPath)">
        </head><body>
        <form class="card" id="f" autocomplete="on"
              data-msg-failed="\#(failed)" data-msg-credentials="\#(credentials)"
              data-msg-offline="\#(offline)">
          <div class="brand"><span class="mk">\#(logoSVG)</span><h1>Goel° Web</h1><div class="sub">\#(htmlEscape(L10n.t("Sign in to control your downloads")))</div></div>
          \#(errHTML)
          <div class="fld"><label>\#(htmlEscape(L10n.t("Username")))</label><input id="u" name="username" autocomplete="username" autofocus></div>
          <div class="fld"><label>\#(htmlEscape(L10n.t("Password")))</label><input id="p" name="password" type="password" autocomplete="current-password"></div>
          <button type="submit">\#(htmlEscape(L10n.t("Sign in")))</button>
          <div class="foot">\#(htmlEscape(L10n.t("Goel° download manager")))<br><span class="warn">⚠</span> \#(htmlEscape(L10n.t("Plain HTTP — use only on a trusted network or behind TLS.")))</div>
        </form>
        <script src="\#(PortalBundle.loginJSPath)"></script>
        </body></html>
        """#
    }

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

    static let logoSVG = ##"<svg viewBox="0 0 48 48"><defs><linearGradient id="lg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5db4f5"/><stop offset="1" stop-color="#2f83e6"/></linearGradient></defs><rect width="48" height="48" rx="10.8" fill="url(#lg)"/><g stroke="#fff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round" fill="none"><circle cx="24" cy="21" r="8.5"/><path d="M32.5 12.5 L32.5 32 Q32.5 36 27 36"/></g><circle cx="38.2" cy="11" r="3.1" fill="#fff"/></svg>"##

    static let faviconDataURI = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'%3E%3Cdefs%3E%3ClinearGradient id='s' x1='0' y1='0' x2='0' y2='1'%3E%3Cstop offset='0' stop-color='%235db4f5'/%3E%3Cstop offset='1' stop-color='%232f83e6'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='48' height='48' rx='10.8' fill='url(%23s)'/%3E%3Cg stroke='%23fff' stroke-width='3.4' stroke-linecap='round' stroke-linejoin='round' fill='none'%3E%3Ccircle cx='24' cy='21' r='8.5'/%3E%3Cpath d='M32.5 12.5 L32.5 32 Q32.5 36 27 36'/%3E%3C/g%3E%3Ccircle cx='38.2' cy='11' r='3.1' fill='%23fff'/%3E%3C/svg%3E"
}

/// Allowlists the theme token embedded into the page so a persisted value can't inject markup.
enum AppThemeToken {
    static let known: Set<String> = ["frost-light", "frost-dark", "dracula", "nord"]
    static func sanitize(_ token: String) -> String {
        known.contains(token) ? token : "frost-dark"
    }
}
