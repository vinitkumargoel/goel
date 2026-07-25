# LEDGER — update this as you go, not at the end

This is the first thing the user reads when they wake up. Keep it current.

Status values: `TODO` · `WIP` · `DONE` · `PARTIAL` · `BLOCKED`

| # | Task | Status | Commit | Screenshot | Notes |
|---|---|---|---|---|---|
| T01 | Xcode project scaffold | DONE | `36c9d07` | `shots/T01-hello.png` | App + widget ext build & launch; App Group resolves on sim |
| T02 | Design system | DONE | `64e8d8e` | `T02-swatches-{dark,light}.png` | ember samples at exactly #FF6B2C / #E85D18 |
| T03 | Model + store | DONE | `9390bdd` | — | 77 tests green |
| T04 | TransferEngine seam | DONE | `bb57513` | — | fixtures reproduce visual.html to 3dp |
| T05 | URLSession engine | DONE | `2b5b3ad` | `final/08-soak-running.png` | 3 concurrent real downloads in the simulator (734 MB) — all three sha256 match |
| T06 | Background handoff | DONE | `f05c1cd` | — | unit-tested only; no real process suspension (needs a device) |
| T07 | Queue screen | DONE | `a622333` | `final/01-queue.png` | matches frame0; Active now keeps a 10-min completed grace so the verified row shows |
| T08 | Detail screen | DONE | `1ce815f` | `final/02-detail.png` | matches frame1; sparkline area-fill bug fixed; tab bar hidden on push |
| T09 | Add sheet | DONE | `255552f` | `final/03-add.png` | matches frame2; detent raised to .fraction(0.66) so "Start paused" is not cut off |
| T10 | Player | DONE | `09b49de` | `final/07-player.png` | plays a 63 %-downloaded file in the simulator, buffer +28 s |
| T11 | Library + Files | DONE | `6ac0fce` | `final/{04-library,11-library-light}.png` | matches frame7; 1 Recent row, not 3 — see REPORT |
| T12 | Settings | DONE | `9daf809` | `final/05-settings.png` | matches frame8; cellular byte counter now has a producer |
| T13 | Live Activity | DONE | `f8c2062` | `final/{14-island-compact,15-island-presentations,16-live-activity}.png` | compact Island verified live over the Home Screen |
| T14 | Widgets | DONE | `2e78982` | `final/17-home-widgets.png` | matches frame6; Lock Screen itself is not screenshot-able — gallery is the proof |
| T15 | App Intents | DONE | `c2fef16` | — | command-file IPC unit-tested; buttons never tapped |
| T16 | Final sweep | DONE | | `final/` | this file + REPORT.md |

## Mockup reference images

`visual.html` has been rendered frame-by-frame with headless Chrome into
`tasks/ios-app/shots/mockup/frameN.png`. **Read these** alongside your simulator
screenshots — that is the comparison the tasks ask for.

| File | Screen | Task |
|---|---|---|
| `mockup/frame0.png` | Downloads — the queue | T07 |
| `mockup/frame1.png` | Detail — parallel segments | T08 |
| `mockup/frame2.png` | Add — metadata resolved before you commit | T09 |
| `mockup/frame3.png` | Player — value at 23%, not 100% | T10 |
| `mockup/frame4.png` | Lock Screen — Live Activity + accessory widgets | T13/T14 |
| `mockup/frame5.png` | Dynamic Island — all four presentations | T13 |
| `mockup/frame6.png` | Home Screen & StandBy widgets | T14 |
| `mockup/frame7.png` | Library — in light mode | T11 |
| `mockup/frame8.png` | Settings — engine capability, phone vocabulary | T12 |

Regenerate with the recipe in `Scripts/ios/mockup-frames.sh`.

## Running log

```
[03:19] T01 started
[03:21] T01 build green; widget extension embeds; App Group container resolves
        (/…/Shared/AppGroup/20F6C2A9…) so no fallback needed on this simulator.
[03:22] T01 committed 36c9d07.
[03:24] Rendered all 9 visual.html frames to PNG via headless Chrome so that
        screenshot comparison is a real image-vs-image check, not from memory.
[03:25] T02/T03/T04 + the T05 range-server harness launched in parallel.
[04:40] Whole project green: 215 tests in 14 suites.
[05:05] Deep-link + launch-route harness added — `simctl` cannot tap, and iOS 26 puts an
        "Open in …?" confirmation in front of `simctl openurl`, so every screen below a tab
        root is reached with `-uiTestingRoute goel://…` at launch instead.
[05:15] First real transfers inside the simulator: 500 MB + 200 MB + 2.1 MB concurrently
        against `range-server.py`. All three sha256 match their sidecars.
[05:20] Play-while-downloading verified on device-like conditions: 120 KB/s throttle,
        player opened at 63 %, playhead advancing, buffer +28 s.
[05:35] Full visual sweep into `shots/final/` — every screen shot and read against its
        mockup frame. Findings in REPORT.md.
[05:50] The XXL sweep caught the detail screen ignoring Dynamic Type completely — its
        type was fixed-point with no `@ScaledMetric` anywhere. `DetailTypo` split into
        `Size` bases + font factories, `filledDetailButton` promoted to a `ViewModifier`
        so its label has somewhere to hang a dynamic property, segment geometry scaled
        off `.caption2`. Default size is byte-identical; re-shot to confirm.
[06:00] Final state: `** BUILD SUCCEEDED **`, 215 tests in 14 suites passed,
        `02/03/05/13` re-shot on the fixed build. REPORT.md written.
[--:--] User asked for a light theme. The tokens were already appearance-adaptive, so this is a
        user-facing choice, not a repaint: added an `Appearance` (System/Light/Dark) preference
        on `AppModel`, applied it at the root with `.preferredColorScheme`, and added a segmented
        picker to Settings. A `goel://settings?at=` scroll anchor + a `-uiTestingAppearance`
        launch arg (ephemeral, never persisted) made the picker and the override screenshot-able.
        Proven with `final/{19,20,21}`: app pinned Light while the device is Dark, override wins.
        Build green, 215 tests still pass.
[--:--] Ran an adversarial multi-agent review of the whole branch (find → refute-by-default verify).
        15 findings survived: 2 HIGH, 7 MEDIUM, 6 LOW. Fixed ALL 15. Highlights:
        · HIGH resume-corruption: background progress was folded into the on-disk checkpoint, so a
          paused/failed handoff could later "complete" a file with a hole of zeros. Split a
          `backgroundReceived` high-water mark out of `job.completed`; `adoptFromDisk` now re-reads
          `jobs[id]` AFTER its await so it can't resurrect an already-finalized download.
        · MED handoff: pausing/parking a handed-off job now clears `handedToBackground` (+ cancels
          the bg task), so a later foreground pass can't silently un-pause it; manifest deletion moved
          inside the serial delegate completion so a same-instant `didFinishDownloadingTo` isn't dropped.
        · MED IPC: the widget Resume button now works for `.waitingForWiFi` (was a dead no-op).
        · MED Live Activity: per-download expiry (not a global latch), so a new download after an 8h
          expiry still gets its own activity.
        · MED: `retry()` surfaces engine errors; Add-sheet no longer freezes the filename when the
          probe fills Name while the field merely has focus; backpressure suspend/resume moved inside
          the lock (was strandable on a race).
        · LOW: Activity.request() backoff; failed-only activity no longer shows 100%/"0 downloads";
          widget ETA uses full-queue speed; thumbnail cache is real LRU; Active-tab grace expires on a
          TimelineView clock; save-picker file walk moved off the main actor.
        Build green (`** BUILD SUCCEEDED **`), `** TEST SUCCEEDED **` — 215 tests in 14 suites pass.
        All uncommitted (commit only when asked).
```

## Decisions I made without asking

- **Build loop is orchestrator-owned.** The machine has 8 cores / 16 GB and one booted
  simulator, so parallel `xcodebuild`/`simctl` from several agents would collide. Sub-agents
  write code; a single serialized loop builds, installs and screenshots. Visual polish is
  then done one screen at a time by an agent that owns the simulator for its turn.
- **`NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` in the app Info.plist.** T05/T09
  need plain-HTTP `http://localhost:8099`. This is a development ATS exception and must be
  removed before any App Store submission — flagged in `REPORT.md`.
- **Signing:** simulator ad-hoc (`CODE_SIGN_IDENTITY = "-"`), not `CODE_SIGNING_ALLOWED=NO`.
  Disabling signing entirely would strip the entitlements and the App Group would not
  resolve, which silently breaks the widgets. `CONVENTIONS.md` suggested the latter; it was
  wrong for this project and the working command is in `Scripts/ios/sim.sh`.
- **`.build` and the generated `.xcodeproj` are gitignored.** xcodegen regenerates the
  project from `project.yml`, which is the committed source of truth.

- **`contiguousPrefix` semantics corrected against the task spec.** `T06-background-handoff.md`
  says the contiguous prefix with segments at 100/78/64/57/41/22 % "ends where segment 1 ends".
  That is wrong. Each segment streams forward from its own `lowerBound`, so once segment 0 is
  complete, segment 1's partial bytes begin exactly at segment 0's end and ARE contiguous with
  it. For 6×1000-byte segments the correct prefix is **1780**, not 1000 (and certainly not the
  3620 sum, which is the corruption bug the rule exists to prevent). Taking the spec literally
  would also make a single sequential segment at 50 % report 0, breaking T10's playable
  watermark. Implemented the correct definition; T06's tests assert it.
- **Mockup arithmetic does not close in two places.** (a) Six *equal* segments at
  100/78/64/57/41/22 % average 60.3 %, but the same frame prints 63 %; the fixtures use
  deliberately unequal segment sizes so both numbers are exact at once — which is also what a
  real dynamic segmenter produces. (b) The home-screen widget prints `4 active · 21.4 GB left`
  at 47 %, but the five queue rows sum to ~29.0 GB at ~24 %. The queue rows are authoritative;
  the widget computes from `SharedSnapshot` and uses the mockup's numbers only for the
  placeholder/snapshot previews.

## Dead ends — do not retry

- **`#expect` cannot wrap a call that takes a trailing closure** (`allSatisfy { }`,
  `contains { }`) — the macro expansion fails to compile. Hoist the expression into a `let`
  and `#expect` the resulting `Bool`.
- **Static members of an `actor` cannot be referenced from a default argument or a
  stored-property initialiser inside that same actor** ("covariant 'Self'"). Hoist them to
  file scope (and make them `public` if a `public` default argument uses them).
