# T08 — Detail screen

**Goal:** the signature screen — frame 2 of `visual.html`. This is the one that sells the
product, because no competitor can draw it. Spend real effort here.

## Build

**`Features/Detail/DetailView.swift`** — top to bottom:

1. **Header** — filename 19pt semibold; source host + mirror count in 11pt monospaced
   tertiary (`releases.ubuntu.com · 3 mirrors`).
2. **The big number** — `63%` at 52pt, weight ~720, `.monospacedDigit()`, with the `%` at
   24pt secondary. Below it: `48.2 MB/s · 44 s remaining` in ember, 14pt.
3. **`SegmentBars`** — the signature visual.
4. **`Sparkline`** — throughput, last 60s.
5. **Stats card** — 2×2 grid: Downloaded, Total, Resume, Checksum. Labels 10.5pt uppercase
   tertiary with letter-spacing; values 16pt semibold, tabular. `Resume: Supported` in green.
6. **Actions** — two buttons: Pause (elevated, secondary) and Share (ember, filled).

Cards: `Theme.Metric.cardRadius` (14), 16pt gutters, `elev1` background.

**`Features/Detail/SegmentBars.swift`**
- Header `PARALLEL CONNECTIONS — 6 ACTIVE`, 11pt uppercase, tracked, secondary.
- One row per segment: 2-digit monospaced id, a **7pt** bar (radius 3.5), a right-aligned
  monospaced percentage.
- Fill: ember gradient `#FF8A4C → #FF6B2C` for active, solid green for complete,
  `elev3` for idle.
- Active bars carry the **sheen sweep** from the mockup — a translucent white gradient
  band traversing the filled portion, ~1.9s linear, repeating. Implement with a
  `TimelineView(.animation)` or a repeating `.linear` animation on an offset mask.
  **Respect `@Environment(\.accessibilityReduceMotion)` — no sheen when it is on.**
- Bars animate to new values, they do not snap.

**`Features/Detail/Sparkline.swift`**
- Draw with `Canvas` (or `Path` in a `GeometryReader`) — not 60 stacked `Rectangle`s.
- Line + area fill: ember at 42% opacity fading to 0 at the bottom.
- 2pt stroke, rounded joins, **emphasized endpoint** — a 3.2pt filled dot at the newest
  sample. That endpoint is what makes it read as live.
- Normalize to the window max, not to an absolute scale, and handle the all-zeros case
  without dividing by zero.
- No axes, no grid. It is a sparkline, not a chart.

## Exit criteria

- Push from a queue row into detail for the ubuntu download.
- `Scripts/ios/sim.sh shot T08-detail`, **Read it**, and compare against frame 2. The six
  bars must read 100 / 78 / 64 / 57 / 41 / 22 with the first one green.
- Take a second shot ~2s later and confirm the sheen has moved and the sparkline endpoint
  advanced — proving it is live, not static.
- Reduce Motion on → shoot again → no sheen, everything else intact.
- `git commit -m "ios(T08): detail screen with parallel segment visualization"`

## Notes

- The sheen is the single most memorable detail in the whole app. Get it smooth. If it
  stutters, you are animating a `LinearGradient`'s stops instead of moving a masked
  overlay — move the mask.
- `52pt` numerals without `.monospacedDigit()` will visibly jump between 62% and 63%.
