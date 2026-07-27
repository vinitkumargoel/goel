# Goel° web portal

The UI served at `/` by the macOS app and the Linux daemon. React + TypeScript,
compiled by Vite and embedded into `GoelCore` as generated Swift.

One codebase, both products: the portal lives in `GoelCore`, and
`RemoteControlServer.swift` (macOS) and `RemoteControlServer+Linux.swift` both
serve the identical bundle through the same `RemoteRouter`. There is no
platform-specific copy to keep in step.

## Build

```sh
cd portal
npm install
npm run build      # typecheck → vite build → regenerate PortalBundle.swift
```

`npm run build` writes `Sources/GoelCore/Remote/Generated/PortalBundle.swift`.
**Commit it along with your source changes.** It is checked in so that
`swift build` works on a machine with no Node installed, and CI rebuilds it and
fails if the committed copy differs.

## Develop

```sh
npm run dev        # http://localhost:5173, proxying the API to 127.0.0.1:8899
```

The dev server proxies `/api`, `/login`, `/logout` and `/stream` to a real
daemon, so you develop against real downloads rather than fixtures. Point it
elsewhere with `GOEL_DEV_TARGET=http://host:port npm run dev`.

You need a running backend with **Settings → Web Access** enabled. On Linux,
`goel` serves it directly.

## Layout

```
src/
  main.tsx              mount, theme-before-paint, token scrub
  App.tsx               view/filter/selection state, actions, menus
  lib/
    types.ts            wire types — mirror RemoteRouter.swift exactly
    api.ts              typed client; 401/403/network failures
    boot.ts             the server's per-session values
    theme.ts            the four themes and where the choice is stored
    format.ts           sizes, speeds, ETAs
    taskKind.ts         status/kind/file-type classification
    clipboard.ts        copy, honest about non-secure contexts
  hooks/
    useTasks.ts         SSE stream with a poll fallback
    useToasts.ts
  components/           Topbar, Sidebar, LibraryView, DetailPanel, FolderPicker, …
  styles/
    themes.css          the four palettes — mirrored from Theme.swift
    portal.css          component styles
  login/                the sign-in page's CSS and JS (no React)
```

## Things worth knowing before you change something

**The wire types are hand-mirrored.** `src/lib/types.ts` matches the `Encodable`
structs in `Sources/GoelCore/Remote/RemoteRouter.swift` field for field. Nothing
generates or checks that correspondence — if you add a field in Swift, add it
there too.

**`themes.css` is the only definition of the four palettes.** It reaches the app
through `main.tsx` and the login page through the codegen. Do not add a second
copy in Swift; a divergent duplicate is what this rewrite removed.

**The CSP forbids inline script and style** (`script-src 'self'`). Anything
inline — an inline `<script>`, a CDN `<link>`, a `new Function` — will be
blocked at runtime. That is also why the server passes its boot values as a
`<script type="application/json">` element rather than an assignment.

**The build must stay one JS file and one CSS file.** `vite.config.ts` disables
code splitting on purpose: a dynamic `import()` would need a CSP relaxation, and
`scripts/codegen.mjs` embeds exactly two artifacts.

**Read-only sessions.** `BOOT.readOnly` hides controls that would be refused,
but it is a courtesy, not a control — the server refuses every POST with a 403
before routing. Never rely on the UI for that.

**The save-folder picker is web-only.** `FolderPicker.tsx` exists because a browser has
no native folder chooser for a *remote* filesystem. The macOS app opens a real
`NSOpenPanel` instead — do not port this to it. Every path it shows comes from
`GET /api/folders`; it never joins or trims one itself, so the containment rule lives in
`SaveFolderBrowser.swift` alone and not in a weaker JavaScript copy.

**The `hide-sm` / `hide-xs` classes in `LibraryView` are load-bearing.** They must match
the narrow-viewport `grid-template-columns` in `portal.css` and be identical between a
header cell and the row cell under it, or a column header ends up over nothing.

**Adding an API route** means: the Swift route, the type in `types.ts`, the
method in `api.ts`, then the component. The `api` layer already handles the 401
redirect and surfaces 403 refusals as toasts, so call sites only handle success.
