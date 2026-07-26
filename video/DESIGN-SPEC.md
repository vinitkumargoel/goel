# Goel° keynote demo — design spec

Mode: **autonomous free creation** (user-selected). Fidelity: **same story, better craft**.
UI source: **HTML recreation** (user-selected, in place of launching the native app).

Supersedes `Assets/videos/goel-keynote-demo.mp4` (49.0s, 1280×720). New master is
1920×1080 @ 30fps, 1905 frames (63.5s). (The plan below was cut at 1606 frames; §5 records why it grew.)

---

## 1. Product brief

**What it is** — Goel° is a native SwiftUI download manager for macOS, plus a headless
`GoelDaemon` on Linux driven by a built-in web portal. HTTP, FTP, SFTP, BitTorrent and
HLS share **one queue** and one interface. Ships fully self-contained: every native
library is bundled, nothing for the user to install.

**Audience** — developers, homelab and media-archive users; secondarily IT buyers
evaluating the commercial licence.

**Where this film runs** — README hero (autoplay-less, click-to-play, muted-first),
the marketing site, and release announcements. It must read with sound off, so every
claim carries an on-screen caption.

**Core selling points, in the order the film makes them**

1. Five protocols, one queue — the thing no other manager does.
2. Real throughput — segmented, resumable, 43 MB/s peak.
3. Live per-file detail — progress, speed, connections, ETA.
4. Real BitTorrent — piece map, seeding, per-file priority.
5. SFTP as a first-class transfer surface, not an afterthought.
6. Capture from the browser you already use.
7. Reachable from the menu bar and from any browser on the network.
8. Four built-in themes.
9. Self-contained — zero Homebrew dependencies.

## 2. Requirement → execution decision table

| Requirement | Source | Effect on this film |
|---|---|---|
| Recreate the existing demo | user | Beat list and stat moments preserved; craft, resolution and pacing rebuilt |
| Recreate UI in HTML, don't launch the app | user | Stage 4 builds a pixel-faithful HTML replica; verified by diff against `Assets/screenshots/desktop.png` |
| 1920×1080 @ 30fps | agent | 720p master is the current weak point; 2× HTML capture removes the resolution ceiling |
| 53.5s (was 49.0s) | agent | Pacing feedback in this library is one-directional — never "too slow". Extra 4.5s is entirely hold/rest budget |
| Mock data only | product | Already illustrative in the existing cut and in the README. Same fictional queue reused verbatim — no live, personal or customer data anywhere |
| No BGM specified | agent | Stage 6 selects a restrained tech-house bed from `assets/audio/bgm/`; SFX carry the accents |
| Sound-off legibility | distribution | Every shot carries a caption; no claim exists only in audio |
| Licence/pricing claims | agent | Out of scope for the film — it sells the product, not the licence. README already covers licensing |

**Data ruling** — the queue contents (Ubuntu/Debian/Fedora ISOs, Big Buck Bunny,
Cosmos S01E04, `project-backup-2026-07.tar.zst`, an `imagenet-mini` zip and a magnet
URI) are fictional demo data, frozen as a static fixture in the HTML replica. No
network access during capture. Same for the SFTP host `home-server` and the portal's
`admin` session.

## 3. Visual direction — "Frost Dark, instrument-grade"

One direction chosen, not three, because the product's own design system is already
opinionated and the previous film established the tone. Deviating would cost fidelity
for no gain.

**Rationale** — Goel° is a precision instrument for people who care about bytes. The
film should feel machined: dark, quiet, exact. Not a startup sizzle reel.

### Colour — lifted from `Sources/GoelApp/Theme.swift` (Frost Dark) and `website/tokens.css`

| Token | Value | Source |
|---|---|---|
| `--canvas` | `#0b0c10` | sampled, `desktop.png` outside the window |
| `--canvas-lift` | `#12141a` | radial lift behind the hero window |
| `--app-bg` | `#191b21` | sidebar surface |
| `--app-bar` | `#22252e` | title bar |
| `--surface` | `#20222b` | detail panel |
| `--row` | `#212329` | list row |
| `--row-sel` | `#333953` | selected row |
| `--accent` | `#8AA2FF` | `AppTheme.frostDark.accent` |
| `--accent-press` | `#738FF5` | `AppTheme.frostDark.accentPress` |
| `--green` | `#4ADE80` | `frostDark.green` |
| `--orange` | `#FBBF6B` | `frostDark.orange` |
| `--red` | `#F87171` | `frostDark.red` |
| `--yellow` | `#FCD34D` | `frostDark.yellow` |
| `--purple` | `#C0A2FB` | `frostDark.purple` |
| `--teal` | `#7FDBE8` | `frostDark.teal` |
| `--indigo` | `#A5B8FF` | `frostDark.indigo` |
| kind: iso | `#FF9F0A → #FF6A00` | `FileType.iso.gradient` |
| kind: video | `#BF5AF2 → #8A3FFC` | `FileType.video.gradient` |
| kind: archive | `#64D2FF → #0A84FF` | `FileType.archive.gradient` |
| kind: app | `#32D74B → #1A9E3A` | `FileType.app.gradient` |
| kind: magnet | `#FF453A → #C91D12` | `FileType.magnet.gradient` |
| theme tint: Dracula | `#282A36` | `AppTheme.dracula.windowTint` |
| theme tint: Nord | `#2E3440` | `AppTheme.nord.windowTint` |

Accent is the **only** hue that leads. Protocol/kind colours appear only where the app
itself uses them — badges and file glyphs. No invented palette anywhere in the film:
title cards, captions, light effects and particles all resolve to `--accent` or ink.

### Type — self-hosted from `website/assets/fonts/`, no third-party requests

- **Display / captions**: Inter (variable, 100–900). The app draws in SF; Inter is
  metric-adjacent, ships in this repo, and is what the marketing site already uses.
- **Numbers / readouts**: IBM Plex Mono 400/500/600 — `--font-display` on the site.
  Every metric in the film (43 MB/s, 62%, 2.40, 5, 4, 0) sets in Plex Mono, so the
  numbers read as instrumentation rather than marketing.
- Scale: hero metric 148px/600; title card 64px/600 tracking −0.02em; caption 26px/500;
  caption sub 17px/400 tracking 0.08em uppercase.

### Motion tokens — derived, not felt

Energy axis: **low-mid** (premium, engineering). Tone axis: **serious**.
Base preset = *professional trust* (fintech/enterprise/B2B).

| Token | Value |
|---|---|
| main duration | 21f @30fps |
| entry easing | `cubic-bezier(0, 0, 0.2, 1)` |
| camera easing | `cubic-bezier(0.22, 1, 0.36, 1)` |
| landing easing (things that hit) | `cubic-bezier(0.16, 1, 0.3, 1)` |
| overshoot | ≤ 1.06 — present, restrained |
| squash | 0 |
| stagger | 4f rows, 6f cards |

**Library override applied**: the preset says "no bounce", but the library's hard ruling
is that anything with a *landing metaphor* needs `y1 > 1`. So fades, pushes and camera
moves stay unbounced; row-embed seams, the odometer lock and the outro wordmark slam
use the landing curve. One motion voice, two registers.

Three words for the finished motion: **precise, weighty, calm.**

**No styleframe rendered.** Justification per pipeline stage 1: the product ships a
strict design system, the palette is extracted from source rather than invented, and a
shipped 49s cut already fixes the tone. The HTML replica built in stage 4 doubles as
the styleframe — it is checked against the real screenshot before any Remotion code is
written.

## 4. Feature → shot mapping

Validated against `gallery/api/library.json`. Each animation technique is protagonist
exactly once; the title card is the designated breathing beat and so repeats by design.

| # | Feature | Card | Variant | Why this card |
|---|---|---|---|---|
| 1 | Brand open | `letterspace-materialize` | — | Quiet letterspaced wordmark on dark ambient; low energy start leaves climb room |
| — | Ambient bed under 1 | `glow-flyline-moves` | `glow-orb-ambient` | Background layer only, not a protagonist |
| 2 | App debut | `neon-frame-orbit-drop` | — | Single-page ceremonial debut: frame first, components drop, camera arcs. Reskinned periwinkle |
| 3 | Five protocols, one queue | `row-embed` | — | "Structured data grows into the page" — literally a queue filling. Accent seam on landing |
| 4 | Peak throughput | `odometer-digit-roll` | — | One ace metric full-screen; digits lock left→right then pulse |
| 5 | Live per-file detail | `graze-face-tour` | — | Low camera grazing the detail panel as terrain; ring, tiles, rows settle as it passes |
| — | Signature transition | `line-carry-transition` | — | A progress bar extends off-screen and corners around into the next panel's frame. The single most on-brand transition available for a download manager |
| 6 | BitTorrent piece map | `wall-reveal-moves` | `bento-light-up` | Pieces completing *are* cells lighting in place. Reveal-in-place, not fly-in — keeps it distinct from shot 3 |
| 7 | SFTP transfer | `paper-plane-messenger` | — | Reskinned: the file chip itself is the messenger, arcing remote pane → local pane. Animates the transfer, not just the browser |
| 8 | Browser capture | `integration-hub-map` | — | Five app icons pop, five light pipes connect to one hub — exactly the claim |
| 9 | Menu-bar extra | `command-palette-summon` | — | Screen dims and blurs, panel drops with overshoot, rows stagger in. Reskinned popover for palette |
| 10 | Web portal | `page-turn-transitions` | `cube-rotate` | Two frontends on one engine = two faces of one solid. Semantic, not decorative |
| 11 | Four themes | `theme-switch-moves` | `theme-sweep-toggle` | The feature itself: skin changes in place under a diagonal boundary |
| 12 | Self-contained, 0 deps + close | `outro-group-photo-launch` | — | Bundled libraries fly in and are absorbed into the icon; wordmark lands at peak |
| — | Breathing beats ×2 | `type-assembly-moves` | `split-text-stagger` | Dark-canvas replacement for the paper title card role |
| — | Seams | `shot-transitions`, `transition-hidden-cut` | per seam | Technique cards; each seam picks one by energy drop |

Rejected and why: `deck-deal-flyin` (second batch-entrance — would make shot 3 and 6
homogeneous); `circle-match-iris` (no circular subject on both sides of any seam once
`line-carry-transition` took the signature slot); `paper-title-card`, `brand-ink-open`,
`paper-craft-moves` (paper/ink skin, wrong material language for this product).

## 5. Storyboard — frame-level timeline @ 30fps, **1905 frames (63.5s)**

Durations grew from the 1606-frame plan above during stage 5. Several cards'
documented rest budgets could not be met at the original lengths, and the library's
pacing feedback is one-directional — every recorded note says "hold longer", none
says "too slow". Rather than downgrade a card's parameters to fit a number, the
number moved.

| # | from | dur | shot | card | content | caption |
|---|---|---|---|---|---|---|
| 1 | 0 | 100 | brand open | letterspace-materialize + glow-orb-ambient | ambient orbs; icon settles; `Goel°` draws in parallel; 30f hold | Every download. One queue. |
| 2 | 100 | 120 | app debut | neon-frame-orbit-drop | accent frame draws, camera arcs L→R, all layers land on one frame | One native app. Five protocols. |
| 3 | 220 | 90 | title card A | split-text-stagger | Five protocols. / One queue. | — |
| 4 | 310 | 125 | queue fill | row-embed | 8 rows descend + flatten + accent seam; last row seats at 87 | one queue · every protocol |
| 5 | 435 | 140 | throughput | odometer-digit-roll | push into the status bar, odometer rolls to `43 MB/s`, lock pulse | peak throughput · segmented & resumable |
| 6 | 575 | 130 | detail panel | graze-face-tour | grazing camera down the detail panel; six blocks fall and seat | live progress · per file |
| 7 | 705 | 150 | signature transition | line-carry-transition | the progress bar extends off-screen and corners into the piece map | — |
| 8 | 855 | 150 | piece map | wall-reveal-moves 式A | six-cell bento light-up rebuilds the BitTorrent view | real BitTorrent |
| 9 | 1005 | 150 | SFTP | paper-plane-messenger | the remote file arcs from the SFTP browser into the queue | browse & transfer over SFTP · host key pinned |
| 10 | 1155 | 90 | title card B | split-text-stagger | Everywhere / you already are. | — |
| 11 | 1245 | 130 | browser capture | integration-hub-map | the page turns; five browser marks pop, then five pipes connect | never miss a download |
| 12 | 1375 | 100 | menu bar | command-palette-summon | desktop dims and blurs, popover drops, rows stagger | right from your menu bar |
| 13 | 1475 | 110 | web portal | page-turn-transitions 式A | the cube turns: native face → portal face | manage from any browser |
| 14 | 1585 | 165 | themes | theme-switch-moves 式A | three diagonal sweeps across four real theme captures | four built-in themes |
| 15 | 1750 | 155 | outro | outro-group-photo-launch | nine elements fly in, the wordmark lands, 75f hold | — |

**Hold budget**: shot 1 hold 30f, shot 2 settle 20f, shot 4 rest 38f, shot 5 hold 60f,
shot 7 rest 36f, shot 8 rest 29f, shot 15 hold 75f. Roughly 290f (9.6s) of deliberate
stillness — 15% of the film.

**Energy curve**: 1 low → 2 mid → 3 rest → 4 mid-high → 5 high → 6 mid → 7 mid →
8 mid-high → 9 mid-high → 10 rest → 11 high → 12 mid → 13 mid-high → 14 high → 15 peak.

### Stated deviations from the cards

Every one is recorded in the header comment of the shot file that makes it.

- **BrandOpen** — glyph set drawn 1.85x the demo's 64px cap height (a brand open on
  1080 cannot use a demo's thumbnail scale), and each glyph's viewBox cropped to its
  own ink with a uniform 4-unit bearing. The demo's single 78-wide box works for
  ten equal-width caps; on `G o e l °` it left `l` and `°` floating. Ink-to-ink
  tracking set to 0.55em rather than the demo's 0.72em — still the card's "wide
  letter-spacing" register, but a four-glyph mixed-case mark loses word-shape above it.
- **AppDebut** — the orbit ARRIVES near flat (rotY 38→4) instead of the demo's
  departure to −26. The demo's subject is an abstract card and the pose is the point;
  here the subject is the product window and the shot has to hand a readable app to
  the caption over it.
- **DetailTour** — one continuous take, not the demo's three cross-faded segments
  (the path is a single straight slide, so the demo's documented black-flash seam
  pitfall does not apply). The capture's 11 boxes are grouped into the six blocks a
  designer would name; toured as 33px key/value rows they collided in flight and the
  right-aligned values interleaved into nonsense. Hover height is the card's
  120px band divided by the camera zoom, because the card's band is screen px and
  these blocks are magnified page px.
- **Throughput** — the push-in ACCELERATES rather than the demo's ease-out, so the
  real status bar's "43 MB/s" is not legible for ten frames before the odometer rolls
  up to it. The flash cut absorbs the abrupt stop.
- **LineCarry** — the ambient orb bed from shot 1 is carried into the 3840-wide world
  and the two world halves are ramped over 700px instead of butted, because the demo's
  60-frame traverse across an empty field read as two seconds of black with a line in
  it, and a hard tone edge tracking across frame read as a render seam.
- **SftpTransfer** — the messenger is the app's 320x60 transfer card, not a cutout of
  the 579x34 table row it is lifted from: a 17:1 sliver banking through the air reads
  as a scratch on the lens. Approach flattened to ~9° and the touchdown moved over the
  queue's list, because the demo's steeper descent drove it into the window's edge.
  Final zoom 1.6 rather than the demo's 3.1 — the subject is 1.8x the demo window's width.
- **MenuBarDrop** — the card's typing/narrowing phase and its caret are omitted. A
  menu-bar popover has no input field.
- **ThemeSweep** — three sweeps instead of the card's one, because the product ships
  four themes. The storyboard's DigitRoll `4` is dropped: the caption already says it,
  and the odometer card allows one number-roll main course per film (shot 5 has it).
- **QueueFill** — improves on the template: the empty-slot patch is a crop of a real
  `app-empty` capture, not a flat colour.
- The storyboard's DigitRoll `5` (shot 4) is likewise dropped, same rule.

## 6. Asset manifest (stage 4 captures these, per this locked storyboard)

Full-page 2× textures: `app-full`, `app-empty` (backplate), `detail-panel`,
`torrent-panel`, `torrent-panel-empty`, `sftp`, `menubar-popover`, `desktop-backdrop`,
`portal`, `theme-frost-dark`, `theme-frost-light`, `theme-dracula`, `theme-nord`.

Element cutouts (transparent): `row-1`…`row-8`, `chip-sftp-file`, `badge-*`,
`ring-62`, `statusbar-speed`, `dep-chip-*` (curl, libssh2, ffmpeg, yt-dlp, SQLite,
Sparkle), browser marks ×5 (reused from `website/index.html` `#lg-*` symbols).

`layout.json`: bbox `{x, y, w, h}` per element in full-page CSS px, plus `pageH` per page.

## 7. Determinism

No `Date.now()`, `Math.random()` or argless `new Date()` anywhere. All pseudo-random
values (orb drift, piece-map fill order, particle seeds) come from `mulberry32` seeded
from element index.
