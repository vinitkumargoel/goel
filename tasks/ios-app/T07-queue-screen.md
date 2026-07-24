# T07 — Queue screen

**Goal:** the app's home. Reproduce frame 1 of `visual.html` ("Downloads — the queue").

## Reference

Open `visual.html`, find the first `figure.device`. Read `.row`, `.ic`, `.rname`, `.rsub`,
`.track`, `.rbtn`, `.seg`, `.tabbar` in the CSS. Those are your measurements.

## Build

**`Goel/RootView.swift`** — `TabView` with 4 tabs: Downloads, Library, Remote, Settings.
Set `.tint(Theme.Color.ember)` at the root; without it the tab bar and controls go system
blue and the whole identity collapses.
"Remote" is a placeholder this milestone — an empty state that says what it will do. Do not
fake it with dummy content.

**`Features/Queue/QueueView.swift`**
- `.navigationTitle("Downloads")`, `.navigationBarTitleDisplayMode(.large)` — 34pt large title.
- Leading `Edit`, trailing `+` (opens T09's sheet), both ember.
- A 3-way `Picker(.segmented)`: Active / All / Done.
- `List` of `DownloadRow`, `.listStyle(.plain)`, separators inset 16pt leading.
- Swipe actions: leading pause/resume, trailing destructive remove.
- Empty state when there is nothing: a line of copy plus a primary action. Not a blank screen.

**`Features/Queue/DownloadRow.swift`** — the load-bearing component:
- 38pt rounded-rect icon, tinted by kind: ember for HTTP, `instrument` cyan for SFTP,
  green for completed, gray for waiting.
- Filename: 15pt, semibold, single line, `.truncationMode(.middle)` — the tail of a
  filename carries the extension and matters more than the middle.
- 4pt progress track, ember fill, hidden entirely when completed.
- Subtitle line, 12.5pt secondary, `.monospacedDigit()`:
  `48.2 MB/s · 3.6 of 5.7 GB · 44s left` with `·` separators. Speed in ember when active.
- Trailing 30pt circular button: pause / play / download-to-share depending on status.
- **Every state from the mockup must render**: downloading, sftp, playable-now,
  waiting-for-Wi-Fi, completed-and-verified.

Animate progress with `.animation(.linear(duration: 0.3), value: fraction)` so the bar
glides rather than jumping at 10 Hz.

## Exit criteria

- Launch with `-uiTestingPreviewEngine` → the five rows from T04 appear, matching the
  mockup's content exactly.
- `Scripts/ios/sim.sh shot T07-queue-dark`, **Read it**, compare side by side with frame 1
  of `visual.html`. Check specifically: large-title size, row rhythm, ember tint on speed,
  4pt bar, separator inset, tab bar icons.
- Also shoot `T07-queue-light` and confirm it is legible and deliberate — not an inversion.
- Also shoot at Dynamic Type XXL (Settings → Accessibility, or
  `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL` as a launch
  arg) and confirm nothing clips.
- `git commit -m "ios(T07): downloads queue screen"`

## Notes

- If rows jitter as numbers change, you missed `.monospacedDigit()`.
- If the list stutters, you are re-rendering every row on every tick — make `Download`
  `Equatable` and let SwiftUI diff, and confirm `DownloadStore` mutates only the changed
  element rather than reassigning the whole array.
