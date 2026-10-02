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
daemon. Point it elsewhere with `GOEL_DEV_TARGET=http://host:port npm run dev`.
You need a running backend with **Settings → Web Access** enabled. On Linux,
`goel` serves it directly.

**Fixture mode (dev only).** `http://localhost:5173/?fixtures` runs the portal
against canned data instead (`src/dev/`): a mock `fetch` and `EventSource` with
the mockup's downloads. Variants: `?fixtures=empty`, `loading`, `error`,
`offline`, `readonly`; add `&theme=light|dark` and `&lang=de`. `src/dev/install.ts`
acts only under `import.meta.env.DEV`, so none of it reaches the production bundle.

## Layout

```
src/
  main.tsx              dev fixtures hook, styles, mount, theme-before-paint, token scrub
  App.tsx               view/filter/selection state, actions, menus — the composition
  lib/                  logic, no React: wire types, api, filters, lanes, queue, theme…
    types.ts            wire types — mirror RemoteRouter.swift exactly
    lanes.ts            the Board's lanes (mirrors DownloadBoardLanes.swift)
    tone.ts             the colour a state is drawn in
    theme.ts            Studio Light / Dark / Auto, and the legacy values
  hooks/                state and effects shared by the views
  components/
    ui/                 Studio primitives: Icon, Art, Ring/Bar, SpeedChart, Menu, Modal, Seg…
    shell/              header, omnibox, rail / phone drawer, tab bar, status bar, banners, toasts
    library/            Board and Table, filter chips, bulk bar, empty states
    detail/             the detail sheet and its panes, player, queue overview
    add/                the add dialog, review, folder picker
    dialogs/            confirm, queue dialogs, shortcuts, command palette
    history/ settings/  the two other views
  styles/
    fonts.css           the self-hosted faces
    themes.css          Studio Light and Dark tokens — every colour lives here
    base.css            primitives (.btn, .chip, .pill, .seg, .art, .ring, .menu, .sheet…), in
    base-controls.css   four parts imported in this order
    base-surfaces.css
    base-layers.css
    shell.css           the app frame
    library.css library-table.css   chips, board · table, selection bar
    detail.css detail-panes.css     the sheet, overview, network · files, queue, player
    dialogs.css history.css settings.css palette.css
  fonts/                Latin-subset woff2 + licences (scripts/subset-fonts.sh)
  login/                the sign-in page's CSS and JS (no React)
  dev/                  fixture mode, dev server only
```

**Themes.** `data-theme` takes `light`, `dark` or `auto` (follows the OS). The
pre-Studio values still work: `frost-light` → light; `frost-dark`, `dracula`,
`nord` → dark. Components never use a colour literal — only the tokens in
`themes.css`.

**Fonts.** Bricolage Grotesque (display), Figtree (UI) and Spline Sans Mono
(figures), subset to Latin by `scripts/subset-fonts.sh` and served same-origin from
`/assets/font-*.woff2` (`font-src 'self'` in the CSP). The codegen embeds them in
`PortalBundle.fonts`; nothing is fetched from Google.

**Breakpoints.** ≤920px narrow (rail slims, detail overlays); ≤600px phone (lanes
stack, detail is a full-screen sheet, the rail becomes a tab bar plus drawer).

## Things worth knowing before you change something

**The wire types are hand-mirrored.** `src/lib/types.ts` matches the `Encodable`
structs in `Sources/GoelCore/Remote/RemoteRouter.swift` field for field. Nothing
generates or checks that correspondence — if you add a field in Swift, add it
there too.

**`themes.css` is the only definition of the palettes.** It reaches the app
through `main.tsx` and the login page through the codegen. Do not add a second
copy in Swift.

**The CSP forbids inline script and style** (`script-src 'self'`). Anything
inline — an inline `<script>`, a CDN `<link>`, a `new Function` — will be
blocked at runtime. That is also why the server passes its boot values as a
`<script type="application/json">` element rather than an assignment.

**The build must stay one JS file and one CSS file** (plus the fonts).
`vite.config.ts` disables code splitting on purpose: a dynamic `import()` would
need a CSP relaxation, and `scripts/codegen.mjs` embeds exactly those artifacts.

**Read-only sessions.** `BOOT.readOnly` hides controls that would be refused,
but it is a courtesy, not a control — the server refuses every POST with a 403
before routing. Never rely on the UI for that.

**The save-folder picker is web-only.** `FolderPicker.tsx` exists because a browser has
no native folder chooser for a *remote* filesystem. The macOS app opens a real
`NSOpenPanel` instead — do not port this to it. Every path it shows comes from
`GET /api/folders`; it never joins or trims one itself.

**The picker has no root, and permissions are not its decision.** It browses wherever the
server process's user can browse. `readable` and `writable` on each entry are `access(2)`
answers from the server — grey out what they say to grey out, and never infer a permission
here. A rule invented in JavaScript about someone else's filesystem is a rule that will be
wrong, and it would be wrong about a security boundary. `SaveFolderBrowser.swift` records
what this reach costs.

**Adding an API route** means: the Swift route, the type in `types.ts`, the
method in `api.ts`, then the component. The `api` layer already handles the 401
redirect and surfaces 403 refusals as toasts, so call sites only handle success.
