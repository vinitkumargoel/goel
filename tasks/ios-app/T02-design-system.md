# T02 — Design system

**Goal:** every color, metric, and formatter the rest of the night uses. Lifted from
`visual.html`, not invented.

## Source of truth

Open `visual.html` and read the `:root` token block. These are the values. Do not
approximate them, do not "improve" them.

| Token | Value | Use |
|---|---|---|
| `ember` | `#FF6B2C` | active transfer, primary CTA, progress fill |
| `ember` (light mode) | `#E85D18` | same role on light ground — shifted for contrast |
| `instrument` | `#5AC8FA` | secondary data, SFTP, sparkline alt |
| `ground` | `#000000` | OLED base |
| `elev1 / elev2 / elev3` | `#1C1C1E` / `#2C2C2E` / `#3A3A3C` | cards, controls, raised |
| `label2 / label3` | `rgba(235,235,245,.60)` / `.30` | secondary / tertiary text |
| `separator` | `rgba(84,84,88,.65)` | hairlines |
| success / danger / warning | `#30D158` / `#FF453A` / `#FF9F0A` | semantic only — never as an accent |

Metrics, from the `figcaption .spec` blocks:

| | |
|---|---|
| Progress bar | **4pt**, fully rounded |
| Segment bar | **7pt**, radius 3.5 |
| Row icon | 38pt, radius 10 |
| Card | radius 14, 16pt gutters |
| Separator | 0.5pt, inset 16pt from leading |
| Switch | 51×31pt (system default — do not restyle) |
| Live Activity / widget | radius 22 |
| Scrubber | 6pt track, 13pt knob |

## Build

**`Goel/DesignSystem/Theme.swift`**
- `enum Theme` with nested `Color` and `Metric` namespaces.
- Colors adapt light/dark. Ember uses `#FF6B2C` dark / `#E85D18` light. Prefer
  `Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ... : ... })` so it responds
  to the trait automatically.
- Use system colors where the mockup used system colors (`.separator`, `.secondaryLabel`)
  so Increase Contrast and Reduce Transparency keep working.

**`Shared/SharedTheme.swift`**
- The subset the widget extension needs (ember, elevations, label ramps). It must not
  import anything app-only — the extension links this file too.

**`Goel/DesignSystem/Formatters.swift`** — pure functions, unit-tested in T03:
- `bytes(_ n: Int64) -> String` → `"5.73 GB"`. Base-10 (`.file` / `ByteCountFormatStyle`),
  matching the mockup. `3.61 GB`, `412.3 MB`, `1.4 GB`.
- `speed(_ bytesPerSec: Double) -> String` → `"48.2 MB/s"`.
- `eta(_ seconds: TimeInterval) -> String` → `"44s left"`, `"1m 42s left"`, `"—"` when unknown.
- `duration(_ s: TimeInterval) -> String` → `"3:42"`, `"−37:18"` for remaining.
- `percent(_ fraction: Double) -> String` → `"63%"`, clamped to 0…1, never `NaN`.
  **Guard non-finite input** — the desktop engine has a documented history of `inf`
  speeds; do not let one reach a view.

**A debug swatch screen** — `Features/Debug/SwatchView.swift`, reachable from the root.
Renders every color as a labeled chip and every metric as a labeled rule. This is what you
screenshot to prove the tokens are right.

## Exit criteria

- Build green.
- `Scripts/ios/sim.sh shot T02-swatches-dark` and `T02-swatches-light` (toggle with
  `xcrun simctl ui "$SIM" appearance light|dark`). **Read both.** Ember must be clearly
  warm-orange in dark and visibly deeper in light — if they look identical you wired it wrong.
- `git commit -m "ios(T02): design tokens and formatters from visual.html"`

## Notes

- Ember on black at `#FF6B2C` is the app's whole identity. If a screen later reads blue,
  something is falling back to `.accentColor` — set the tint at the root in T07.
- Semantic colors are reserved. Green means verified/complete, red means failure/destructive.
  Never use them because a row "needed some variety."
