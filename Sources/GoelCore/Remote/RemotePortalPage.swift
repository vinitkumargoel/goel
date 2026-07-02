import Foundation

/// The embedded web portal — the full control app served at `/`, plus the login
/// page served at `/login`. Kept apart from the router's logic because it is one
/// large, mostly-static artifact.
///
/// It ships the **same four named themes as the desktop app** (Frost Light, Frost
/// Dark, Dracula, Nord), with palettes mirrored from `Theme.swift`. The active
/// theme is chosen per-browser (persisted in `localStorage`), defaulting to the
/// server's `remoteTheme` — so the web look is fully independent of the desktop's,
/// exactly as intended.
extension RemoteRouter {

    /// The full control portal. Auth is by session cookie (or `?token=` for
    /// scripts); the page embeds no secret. A small `BOOT` object seeds the
    /// default theme, the signed-in username, and read-only state.
    static func page(config: Config) -> String {
        let boot = bootJSON(config: config)
        return #"""
        <!doctype html><html lang="en" data-theme="frost-dark"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Goel° — Web Portal</title>
        <link rel="icon" type="image/svg+xml" href="\#(faviconDataURI)">
        <style>\#(themeCSS)\#(portalCSS)</style></head>
        <body>
        <div class="topbar">
          <button class="hamburger" id="hamburger" aria-label="Menu"><svg viewBox="0 0 24 24" fill="none"><path d="M4 6h16M4 12h16M4 18h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button>
          <div class="brand"><span class="mk">\#(logoSVG)</span>Goel° <span class="sub">WEB</span></div>
          <div class="search"><svg viewBox="0 0 24 24" fill="none"><circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="2"/><path d="M21 21l-4-4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><input id="search" placeholder="Search downloads"></div>
          <div class="spacer"></div>
          <div class="stats"><span class="stat down"><svg viewBox="0 0 24 24" fill="none"><path d="M12 4v14m0 0l-5-5m5 5l5-5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><b id="down">0 B/s</b></span><span class="stat up"><svg viewBox="0 0 24 24" fill="none"><path d="M12 20V6m0 0l-5 5m5-5l5 5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><b id="up">0 B/s</b></span></div>
          <button class="add-btn" id="btnAdd"><svg viewBox="0 0 24 24" fill="none"><path d="M12 5v14M5 12h14" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg><span class="lbl">Add</span></button>
          <button class="ico" id="btnPanel" title="Detail panel"><svg viewBox="0 0 24 24" fill="none"><rect x="3" y="4" width="18" height="16" rx="2" stroke="currentColor" stroke-width="2"/><path d="M15 4v16" stroke="currentColor" stroke-width="2"/></svg></button>
          <button class="user" id="btnUser"><span class="avatar" id="avatar">A</span><span class="uname" id="uname">admin</span><svg viewBox="0 0 24 24" fill="none"><path d="M6 9l6 6 6-6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        </div>
        <div class="shell">
          <div class="sb-backdrop" id="sbBackdrop"></div>
          <div class="sidebar" id="sidebar">
            <div class="s-lbl">Library</div>
            <div class="s-item active" data-view="library" data-filter="all"><svg viewBox="0 0 24 24" fill="none"><path d="M3 7h18M3 12h18M3 17h18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span class="l">All downloads</span><span class="ct" data-c="all">0</span></div>
            <div class="s-lbl">Status</div>
            <div class="s-item" data-view="library" data-filter="active"><svg viewBox="0 0 24 24" fill="none"><path d="M12 3v11m0 0l-4-4m4 4l4-4M5 19h14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="l">Active</span><span class="ct" data-c="active">0</span></div>
            <div class="s-item" data-view="library" data-filter="paused"><svg viewBox="0 0 24 24" fill="none"><path d="M8 5v14M16 5v14" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span class="l">Paused</span><span class="ct" data-c="paused">0</span></div>
            <div class="s-item" data-view="library" data-filter="completed"><svg viewBox="0 0 24 24" fill="none"><path d="M20 6L9 17l-5-5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="l">Completed</span><span class="ct" data-c="completed">0</span></div>
            <div class="s-item" data-view="library" data-filter="seeding"><svg viewBox="0 0 24 24" fill="none"><path d="M12 21V8m0 0l-4 4m4-4l4 4M5 5h14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="l">Seeding</span><span class="ct" data-c="seeding">0</span></div>
            <div class="s-item" data-view="library" data-filter="failed"><svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="2"/><path d="M12 8v4m0 4h.01" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span class="l">Failed</span><span class="ct" data-c="failed">0</span></div>
            <div class="s-lbl">Tools</div>
            <div class="s-item" data-view="history"><svg viewBox="0 0 24 24" fill="none"><path d="M3 12a9 9 0 109-9 9 9 0 00-7 3.3M3 4v4h4M12 7v5l3 2" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="l">History</span></div>
            <div class="s-item" data-view="settings"><svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="2"/><path d="M19.4 15a1.6 1.6 0 00.3 1.8l.1.1a2 2 0 11-2.9 2.8l-.1-.1a1.6 1.6 0 00-2.7 1.1V21a2 2 0 11-4 0 1.6 1.6 0 00-2.7-1.1l-.1.1a2 2 0 11-2.8-2.9l.1-.1a1.6 1.6 0 00-1.1-2.7H3a2 2 0 110-4 1.6 1.6 0 001.1-2.7l-.1-.1a2 2 0 112.8-2.8l.1.1A1.6 1.6 0 009 4.6V4a2 2 0 114 0 1.6 1.6 0 002.7 1.1l.1-.1a2 2 0 112.8 2.8l-.1.1a1.6 1.6 0 001.1 2.7H21a2 2 0 110 4h-.6a1.6 1.6 0 00-1 .4z" stroke="currentColor" stroke-width="1.5"/></svg><span class="l">Settings</span></div>
          </div>
          <div class="content">
            <div class="view" id="v-library">
              <div id="roBanner" class="ro-banner" hidden>Read-only mode — viewing &amp; streaming only. Changes are disabled by the host.</div>
              <div class="lhead"><div>Name</div><div class="r">Size</div><div class="hide-xs">Status</div><div class="r hide-xs">↓ Speed</div></div>
              <div class="rows" id="rows"></div>
            </div>
            <div class="view" id="v-history" hidden><div class="pad" id="histPad"></div></div>
            <div class="view" id="v-settings" hidden><div class="pad" id="setPad"></div></div>
          </div>
          <div class="detail" id="detail"><div id="detailBody"></div></div>
        </div>
        <div class="statusbar"><span class="sb-dim" id="sbCount">—</span><div class="sp"></div><span class="sb-dim">Signed in · <span id="sbUser">admin</span></span></div>
        <div class="scrim" id="scrim"></div>
        <div class="toasts" id="toasts"></div>
        <script>const BOOT=\#(boot);</script>
        <script>\#(portalJS)</script>
        </body></html>
        """#
    }

    /// The login page (served at `/login`). A minimal themed form that POSTs
    /// JSON credentials to `/login`; on success the server sets the session cookie
    /// and the page redirects to `/`.
    static func loginPage(theme: String, error: String?) -> String {
        let themeAttr = AppThemeToken.sanitize(theme)
        let errHTML = error.map { #"<div class="err">\#(htmlEscape($0))</div>"# } ?? ""
        return #"""
        <!doctype html><html lang="en" data-theme="\#(themeAttr)"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Goel° — Sign in</title>
        <link rel="icon" type="image/svg+xml" href="\#(faviconDataURI)">
        <style>\#(themeCSS)
        *{box-sizing:border-box;margin:0;padding:0}
        body{min-height:100vh;display:grid;place-items:center;padding:24px;background:var(--bg-app);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
        .card{width:380px;max-width:100%;background:var(--bg-window);border:1px solid var(--border-strong);border-radius:18px;box-shadow:0 30px 70px rgba(0,0,0,.5);padding:34px 30px 26px}
        .brand{display:flex;flex-direction:column;align-items:center;gap:12px;margin-bottom:22px}
        .mk{width:60px;height:60px;border-radius:15px;box-shadow:0 10px 24px rgba(0,0,0,.35);overflow:hidden}
        .mk svg{width:100%;height:100%;display:block}
        h1{font-size:21px;font-weight:700}.sub{font-size:13px;color:var(--text-dim);margin-top:-6px}
        label{display:block;font-size:12px;font-weight:600;color:var(--text-dim);margin:0 0 6px}
        .fld{margin-bottom:14px}
        input{width:100%;height:42px;background:var(--bg-input);border:1px solid var(--border);border-radius:10px;padding:0 12px;font-size:14px;color:var(--text)}
        input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
        button{width:100%;height:42px;border:0;border-radius:10px;background:var(--accent);color:#fff;font-size:14px;font-weight:600;cursor:pointer;margin-top:6px}
        button:hover{background:var(--accent-press)}
        .err{background:var(--red-soft);color:var(--red);font-size:12.5px;border-radius:9px;padding:9px 11px;margin-bottom:14px;text-align:center}
        .foot{margin-top:20px;padding-top:16px;border-top:1px solid var(--border);text-align:center;font-size:11.5px;color:var(--text-faint);line-height:1.6}
        .warn{color:var(--orange)}
        </style></head><body>
        <form class="card" id="f" autocomplete="on">
          <div class="brand"><span class="mk">\#(logoSVG)</span><h1>Goel° Web</h1><div class="sub">Sign in to control your downloads</div></div>
          \#(errHTML)
          <div class="fld"><label>Username</label><input id="u" name="username" autocomplete="username" autofocus></div>
          <div class="fld"><label>Password</label><input id="p" name="password" type="password" autocomplete="current-password"></div>
          <button type="submit">Sign in</button>
          <div class="foot">Goel° download manager<br><span class="warn">⚠</span> Plain HTTP — use only on a trusted network or behind TLS.</div>
        </form>
        <script>
        const f=document.getElementById('f');
        f.addEventListener('submit',async e=>{
          e.preventDefault();
          const btn=f.querySelector('button');btn.disabled=true;
          try{
            const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({username:document.getElementById('u').value,password:document.getElementById('p').value})});
            if(r.ok){location.href='/';return;}
            const j=await r.json().catch(()=>({error:'Sign-in failed'}));
            show(j.error||'Wrong username or password');
          }catch(_){show('Could not reach the server');}
          btn.disabled=false;
        });
        function show(m){let e=document.querySelector('.err');if(!e){e=document.createElement('div');e.className='err';f.insertBefore(e,f.children[1]);}e.textContent=m;}
        </script></body></html>
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

    // MARK: Themes — mirrored from Theme.swift (frost-light / frost-dark / dracula / nord)

    static let themeCSS = #"""
    :root{font-synthesis:none}
    html[data-theme="frost-light"]{
      --bg-app:#dfe3ee;--bg-window:#eef0f4;--bg-bar:rgba(250,250,252,.82);--bg-sidebar:rgba(238,240,244,.86);--bg-content:#fbfcfe;--bg-panel:rgba(245,246,250,.82);
      --bg-row-alt:rgba(0,0,0,.022);--bg-row-hover:rgba(0,0,0,.045);--bg-row-sel:rgba(63,88,214,.14);
      --bg-input:rgba(0,0,0,.05);--bg-chip:rgba(0,0,0,.06);--bg-control:rgba(0,0,0,.05);--bg-control-active:rgba(0,0,0,.1);--track:rgba(0,0,0,.1);--bg-modal:#f6f7fa;
      --text:#1a1c22;--text-dim:#5a616f;--text-faint:#9198a6;--border:rgba(0,0,0,.09);--border-strong:rgba(0,0,0,.14);--seg-empty:rgba(0,0,0,.08);--scrim:rgba(0,0,0,.32);
      --accent:#3F58D6;--accent-press:#2E45B8;--accent-soft:rgba(63,88,214,.18);--green:#158A3C;--orange:#A85800;--red:#CE0E0E;--red-soft:rgba(206,14,14,.12);--yellow:#8A6D00;--purple:#7A3FD0;--teal:#0E7490;--indigo:#3F58D6;color-scheme:light}
    html[data-theme="frost-dark"]{
      --bg-app:#15171d;--bg-window:#1e2027;--bg-bar:rgba(28,30,37,.72);--bg-sidebar:rgba(24,26,32,.72);--bg-content:#1c1e25;--bg-panel:rgba(40,43,53,.7);
      --bg-row-alt:rgba(255,255,255,.022);--bg-row-hover:rgba(255,255,255,.05);--bg-row-sel:rgba(138,162,255,.24);
      --bg-input:rgba(255,255,255,.07);--bg-chip:rgba(255,255,255,.08);--bg-control:rgba(255,255,255,.09);--bg-control-active:rgba(255,255,255,.16);--track:rgba(255,255,255,.1);--bg-modal:#252831;
      --text:#eef1f7;--text-dim:#9aa3b4;--text-faint:#6a7285;--border:rgba(255,255,255,.09);--border-strong:rgba(255,255,255,.15);--seg-empty:rgba(255,255,255,.08);--scrim:rgba(0,0,0,.55);
      --accent:#8AA2FF;--accent-press:#738FF5;--accent-soft:rgba(138,162,255,.2);--green:#4ADE80;--orange:#FBBF6B;--red:#F87171;--red-soft:rgba(248,113,113,.16);--yellow:#FCD34D;--purple:#C0A2FB;--teal:#7FDBE8;--indigo:#A5B8FF;color-scheme:dark}
    html[data-theme="dracula"]{
      --bg-app:#21222c;--bg-window:#282a36;--bg-bar:rgba(40,42,54,.82);--bg-sidebar:rgba(33,34,44,.9);--bg-content:#282a36;--bg-panel:rgba(52,55,70,.72);
      --bg-row-alt:rgba(255,255,255,.02);--bg-row-hover:rgba(255,255,255,.05);--bg-row-sel:rgba(189,147,249,.24);
      --bg-input:rgba(255,255,255,.07);--bg-chip:rgba(255,255,255,.08);--bg-control:rgba(255,255,255,.08);--bg-control-active:rgba(255,255,255,.15);--track:rgba(255,255,255,.1);--bg-modal:#343746;
      --text:#f8f8f2;--text-dim:#b8bed6;--text-faint:#6272a4;--border:rgba(248,248,242,.1);--border-strong:rgba(248,248,242,.16);--seg-empty:rgba(255,255,255,.08);--scrim:rgba(0,0,0,.55);
      --accent:#BD93F9;--accent-press:#A97BF0;--accent-soft:rgba(189,147,249,.22);--green:#50FA7B;--orange:#FFB86C;--red:#FF6E6E;--red-soft:rgba(255,110,110,.16);--yellow:#F1FA8C;--purple:#FF79C6;--teal:#8BE9FD;--indigo:#BD93F9;color-scheme:dark}
    html[data-theme="nord"]{
      --bg-app:#2b303b;--bg-window:#2e3440;--bg-bar:rgba(46,52,64,.82);--bg-sidebar:rgba(43,48,59,.9);--bg-content:#2e3440;--bg-panel:rgba(59,66,82,.72);
      --bg-row-alt:rgba(255,255,255,.02);--bg-row-hover:rgba(255,255,255,.05);--bg-row-sel:rgba(136,192,208,.22);
      --bg-input:rgba(255,255,255,.06);--bg-chip:rgba(255,255,255,.08);--bg-control:rgba(255,255,255,.08);--bg-control-active:rgba(255,255,255,.14);--track:rgba(255,255,255,.1);--bg-modal:#3b4252;
      --text:#eceff4;--text-dim:#a8b1c4;--text-faint:#69748c;--border:rgba(236,239,244,.1);--border-strong:rgba(236,239,244,.16);--seg-empty:rgba(255,255,255,.08);--scrim:rgba(0,0,0,.55);
      --accent:#88C0D0;--accent-press:#81A1C1;--accent-soft:rgba(136,192,208,.2);--green:#A3BE8C;--orange:#D08770;--red:#E08691;--red-soft:rgba(224,134,145,.16);--yellow:#EBCB8B;--purple:#B48EAD;--teal:#8FBCBB;--indigo:#81A1C1;color-scheme:dark}
    """#

    // MARK: Portal CSS + JS (loaded from adjacent files' string constants)

    static let portalCSS = RemotePortalAssets.css
    static let portalJS = RemotePortalAssets.js
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
