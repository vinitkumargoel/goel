# T14 — Widgets + the debug gallery

**Goal:** frames 5 and 7 of `visual.html`. Ambient, aggregate truth — deliberately **not**
live. Plus the in-app gallery that lets you actually verify them.

## The rule that governs this whole task

WidgetKit grants a **budget** of timeline reloads per day (tens, not thousands). These
widgets show slow-moving aggregate state — `4 active · 21.4 GB left` — never a per-second
number. PRD §6.5: *"Widgets never contradict the Live Activity by more than one refresh
interval."* Scope them so they cannot.

They read `SharedSnapshot` from the App Group (T03). They do **not** contain transfer logic.

## Build

**`GoelWidgets/AccessoryWidgets.swift`** — lock screen:
- `.accessoryCircular` — `Gauge` or a ring with the aggregate percent in the center.
- `.accessoryRectangular` — `DOWNLOADING` label, top filename truncated, aggregate line
  `63% · 2.1 GB left · 44s`.
- `.accessoryInline` — one line: `↓ 4 active · 21.4 GB`.
- Use `.widgetAccentable()` and honor `.widgetRenderingMode` — accessory widgets render
  in a vibrant monochrome mode on the Lock Screen and a hardcoded ember will be ignored or
  look wrong.

**`GoelWidgets/HomeWidgets.swift`**:
- **Small** — `Goel°` header with glyph, big `4`, `active · 21.4 GB left`, a 4pt aggregate
  bar. Radius 22, `elev1` at ~84% with a hairline border.
- **Medium** — `QUEUE` header, three rows of name + percent, each with its own 4pt bar
  (ember, ember, cyan per the mockup).
- A second small variant — `FASTEST`: `48.2 MB/s` with a mini sparkline.
- Deep-link into the app via `.widgetURL(URL(string: "goel://download/<id>"))`; handle the
  scheme in `GoelApp` and route to the detail screen.

**Timeline provider:** read the snapshot, emit entries at a **15-minute** cadence with
`.after(...)`. Do not use `.atEnd` with a tight loop. `placeholder` and `snapshot` must
render instantly with plausible data — the gallery and the widget picker both use them.

**`Goel/Features/Debug/WidgetGalleryView.swift`** — the verification surface.

Because `simctl` cannot lock the simulator, this screen renders the **real widget SwiftUI
views** (import them directly — they live in `Shared/`-adjacent files compiled into both
targets, or factor the view bodies into `Shared/`) inside containers at exact dimensions:

| Family | Frame |
|---|---|
| accessoryCircular | 76 × 76 |
| accessoryRectangular | 172 × 76 |
| accessoryInline | 200 × 24 |
| systemSmall | 158 × 158 |
| systemMedium | 338 × 158 |
| Live Activity lock-screen | 365 × auto |

Render each on a dark blurred ground so it reads like a Lock Screen, labeled. Reachable
from Settings → a `#if DEBUG` row. This is how you prove the lock-screen surfaces are
right without a lock screen.

## Exit criteria

- `Scripts/ios/sim.sh shot T14-gallery`, **Read it**. All six render, none clipped, none
  showing placeholder junk.
- Add a real widget to the simulator home screen (long-press → Edit → Add Widget) and
  screenshot `T14-homescreen.png`. Compare to frame 7.
- Change state in the app → confirm the widget updates within a reload cycle (force it
  with `WidgetCenter.shared.reloadAllTimelines()`).
- `git commit -m "ios(T14): accessory and home screen widgets plus debug gallery"`

## Notes

- If widgets show blank, the App Group is the near-certain cause. Check
  `xcrun simctl get_app_container "$SIM" dev.goel.ios groups` and confirm both targets
  carry the entitlement.
- Widget memory limits are small. Do not decode the full download list — that is exactly
  why `SharedSnapshot` caps `top` at 3.
