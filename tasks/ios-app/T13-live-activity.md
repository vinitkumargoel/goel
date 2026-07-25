# T13 — Live Activity + Dynamic Island

**Goal:** the hero surface. Read `docs/PRD-iOS.md` §6.5 in full first — it is the most
precise section in the document and it is all binding.

Reference: `visual.html` frames 5 and 6. **Frame 6 shows all four presentations**,
including the degraded one.

## Build

**`Shared/DownloadActivityAttributes.swift`** — member of both targets.

```
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var filename: String
        var receivedBytes: Int64
        var totalBytes: Int64?
        var fraction: Double
        var speed: Double
        var eta: TimeInterval?
        var isAggregate: Bool      // "3 downloads · 62%"
        var activeCount: Int
        var updatedAt: Date
    }
    var downloadID: String
    var kindToken: String
}
```

**`GoelWidgets/LiveActivityWidget.swift`** — `ActivityConfiguration`, four presentations,
all four designed:

1. **Lock Screen / banner** — 30pt ember-tinted glyph, filename (truncating), byte counts
   and speed on a secondary line, `63%` at 20pt trailing, a 4pt ember progress bar, then
   **Pause** and **Cancel** buttons (Cancel in red). Radius 22, hairline border.
2. **Compact** — leading: kind glyph. Trailing: a circular progress ring, ember on a 20%
   white track, `.rotationEffect(-90°)`, rounded cap.
3. **Minimal** — the ring alone.
4. **Expanded** — `DynamicIslandExpandedRegion`s: leading glyph, trailing percent, center
   filename + speed/ETA, bottom the progress bar and both buttons.

**Honest degradation — the part most implementations get wrong.**
Publish with `ActivityContent(state:staleDate:)`, `staleDate` ≈ 90s out. In the stale
branch (`context.isStale`):
- Do **not** show a percentage or an ETA.
- Show the byte count and `updated 2 min ago` (relative, from `updatedAt`).
- Desaturate the progress bar to a neutral gray.

This is drawn explicitly in `visual.html` frame 6, fourth state. It exists because during a
background `URLSession` the app is not running and any precise number would be a lie.

**`Goel/LiveActivity/ActivityController.swift`** (app side)
- Start an activity within **1s** of a download starting (a PRD acceptance criterion).
- **Aggregation rule:** more than one active download → a single aggregate activity
  (`3 downloads · 62%`); collapse to per-file when one remains. Never one activity per
  download.
- Update at most every ~2s while foregrounded; on every background `URLSession` delegate
  wake while backgrounded. Do not update per byte.
- `Activity.end(_:dismissalPolicy: .after(...))` on completion.
- Handle expiry: ActivityKit allows ~8h of updates, ~12h visible. On expiry, post a local
  completion notification instead. A multi-hour download will outlive its activity.
- Guard `ActivityAuthorizationInfo().areActivitiesEnabled` and degrade silently.

## Exit criteria

- Start a download, background the app with
  `xcrun simctl launch "$SIM" com.apple.springboard`, screenshot →
  `T13-island-compact.png`. **Read it.** The ring must be visible in the Island.
- Long-press the Island (`xcrun simctl` cannot; use the Simulator UI via a click if you can,
  otherwise render the expanded layout in the T14 gallery and note the limitation).
- Force the stale branch — add a debug toggle that publishes with a `staleDate` already in
  the past — screenshot `T13-island-stale.png` and confirm no percentage is shown.
- With 3 active downloads, confirm exactly **one** aggregate activity exists.
- `git commit -m "ios(T13): live activity and dynamic island, all four presentations"`

## Notes

- `NSSupportsLiveActivities` must be `true` in the **app's** Info.plist (T01). Without it
  `Activity.request` throws and it is easy to misread as an entitlement problem.
- Live Activities work on the simulator. The Lock Screen cannot be shown from `simctl` —
  verify the lock-screen layout through the T14 gallery instead, and say so in `REPORT.md`.
- **Do not build a push server.** §6.5 rejects it explicitly. App-driven updates only.
