# Goel° iOS — overnight build report

## TL;DR

The app builds, installs, launches, and **actually moves bytes**: three concurrent downloads
(500 MB + 200 MB + 2.1 MB) ran to completion inside the simulator against a local range server
and all three SHA-256 digests match their sidecars exactly. A 60-second video was played back
**while it was still downloading** at 63 %, with the playhead advancing and 28 s of buffer ahead
of it. 215 tests in 14 suites are green. Every screen has been screenshotted and compared against
its `visual.html` frame — the shots are in `tasks/ios-app/shots/final/` and the comparison is in
the Screens table below.

**Look at first:** `shots/final/02-detail.png` next to `shots/mockup/frame1.png` — the segmented
transfer screen is the thing no competitor draws, and it is the closest match in the build.

**The three real gaps:** the background handoff has never had a process genuinely suspended (it
is proven by unit tests only, and that needs a device); nothing has been tested on a Lock Screen
(the simulator cannot lock, so the Live Activity and accessory widgets are verified through an
in-app gallery that instantiates the real widget views); and the App Intent buttons in the Live
Activity have never been tapped — the command-file IPC behind them is unit-tested, the buttons
are not.

## Run it

```bash
cd /Users/homepc/.superset/worktrees/goel/ios-app
git checkout ios-app-impl

# Build, install, launch with the deterministic fixture engine (this is what the shots show):
./Scripts/ios/sim.sh preview

# Or with the real engine and nothing in the queue:
./Scripts/ios/sim.sh run

# Every test:
xcodebuild -project apps/ios/Goel.xcodeproj -scheme Goel \
  -destination "platform=iOS Simulator,id=BC332A27-A788-413C-910B-7686447B73F1" \
  -derivedDataPath apps/ios/.build test
```

Reaching a screen below a tab root from a script (`simctl` cannot tap, and iOS 26 puts an
"Open in Goel°?" confirmation in front of `simctl openurl` that nothing can dismiss):

```bash
SIM=BC332A27-A788-413C-910B-7686447B73F1
xcrun simctl launch "$SIM" dev.goel.ios -uiTestingPreviewEngine \
  -uiTestingRoute "goel://download/60E160E1-0000-4000-8000-000000000001"   # detail
#  goel://add?url=<percent-encoded>     goel://library     goel://settings
#  goel://player/<uuid>                 goel://debug/widgets?at=island
```

Reproduce the real-transfer soak:

```bash
python3 Scripts/ios/range-server.py --throttle 20000000 &     # serves Scripts/ios/fixtures/
xcrun simctl launch "$SIM" dev.goel.ios -uiTestingRoute \
  "goel://start?url=http%3A%2F%2Flocalhost%3A8099%2Ftest-500mb.bin\
&url=http%3A%2F%2Flocalhost%3A8099%2Ftest-200mb.bin\
&url=http%3A%2F%2Flocalhost%3A8099%2Fsample-video.mp4"
# then:
C=$(xcrun simctl get_app_container "$SIM" dev.goel.ios data)
shasum -a 256 "$C"/Documents/Goel°/*        # compare with Scripts/ios/fixtures/*.sha256
kill %1
```

`goel://start` is `#if DEBUG` only.

## Screens

| Screen | Shot | Matches mockup? | Notes |
|---|---|---|---|
| Queue | `final/01-queue.png` | yes, frame0 | All five states present. Toolbar buttons and tab bar wear the iOS 26 "glass" treatment the mockup predates — not controllable from the app. |
| Detail | `final/02-detail.png` | yes, frame1 | Sparkline was drawing a wedge instead of an area fill; fixed. Share is deliberately disabled mid-transfer with a reason line the mockup does not have. |
| Add sheet | `final/03-add.png` | yes, frame2 | "Save to" reads `Goel°` where the mockup shows `Goel° › Linux` (no subfolder chosen by default). The link field truncates at the tail; the mockup elides the middle. |
| Library | `final/04-library.png` | structure yes, content no | frame7 lists three recent files; the app lists one. See Known bugs. |
| Settings | `final/05-settings.png` | yes, frame8 | "Maximum connections" is a stepper, not a static number. "Paired with" says `Nothing yet · Coming in 1.2` rather than `vinit's Mac · Linked`. |
| Widget gallery | `final/06-widget-gallery.png` | n/a | The verification surface for everything that cannot be screenshotted. |
| Player | `final/07-player.png` | yes, frame3 | Real playback of a 63 %-complete file. Our fixture is 60 s, the mockup's is 41 min, so every number differs. |
| Player (complete) | `final/07b-player-complete.png` | n/a | Same screen once the file lands: `Playing the complete file — 2.1 MB`. |
| Soak | `final/08-soak-running.png` | n/a | Three real transfers finished; this is the evidence for the checksums. |
| Queue (light) | `final/09-queue-light.png` | yes | Ember holds against a light ground; nothing illegible. |
| Detail (light) | `final/10-detail-light.png` | yes | Segment-bar gradients read better here than on black. |
| Library (light) | `final/11-library-light.png` | yes, frame7 | frame7 is the light-mode frame; palette matches. |
| Queue (XXL) | `final/12-queue-xxl.png` | n/a | Titles middle-truncate, subtitles wrap to two lines, nothing clips. |
| Detail (XXL) | `final/13-detail-xxl.png` | n/a | This screen ignored Dynamic Type entirely until the final sweep — its type was fixed-point with no `@ScaledMetric`. Now the title wraps, the labels and bars grow, and the stats card scrolls below the fold. Default size is byte-identical. |
| Dynamic Island (live) | `final/14-island-compact.png` | yes, frame5 | Taken on the Home Screen with the app backgrounded — a real Live Activity, not a mock. |
| Dynamic Island (all four) | `final/15-island-presentations.png` | yes, frame5 | Compact, minimal, expanded, and the degraded/stale presentation. |
| Live Activity | `final/16-live-activity.png` | yes, frame4 | Lock Screen live, aggregate, and stale. |
| Home widgets | `final/17-home-widgets.png` | yes, frame6 | `4 active · 21.4 GB left`, FASTEST, and the three-row queue. |
| Files app | `final/18-files-app.png` | no | Files opens on an empty "Recents". Browsing to `On My iPhone › Goel°` needs taps. |
| Appearance picker | `final/19-settings-appearance.png` | n/a (added) | Not in the dark-only mockup. Segmented `System / Light / Dark` in Settings; `System` selected by default. |
| Light override — Queue | `final/20-queue-light-override.png` | n/a (added) | App pinned to Light while the **device is Dark** — the in-app choice wins. Ember, sftp-blue and the verified-green chip all hold on the light ground. |
| Light override — Settings | `final/21-settings-appearance-light.png` | n/a (added) | Same override, showing the picker on `Light` with the whole screen rendered light over a dark device. |

## Works

| Feature | Evidence |
|---|---|
| Segmented multi-connection HTTP download | 3 concurrent transfers, 734 MB, in the simulator — `sha256` of all three outputs equals the fixture sidecars (`final/08-soak-running.png`) |
| Byte-exact resume from a partial file | `SegmentMathTests`, `HandoffTests`; and the 200 MB kill-and-resume run in the T05 harness |
| Range/`If-Range` correctness, 416, redirect, no-ranges fallback | `Scripts/ios/range-server.py` self-test; `PreviewEngineTests` |
| Play while downloading | `final/07-player.png` — playhead 0:10 of 1:00 at 63 % downloaded, buffer +28 s, `MODE Sequential` |
| Metadata probe before commit | `final/03-add.png` — name, 5.73 GB, `Disk Image · resumable` all resolved before the button is enabled |
| Live Activity + Dynamic Island | `final/14-island-compact.png` — the compact presentation running over SpringBoard |
| Widget rendering at real WidgetKit dimensions | `final/{06,15,16,17}` |
| Command-file IPC for widget-process intents | `CommandFileTests` (24-thread concurrent append, idempotency ledger, staleness) |
| Cellular byte accounting | `SettingsPolicyTests` for the ledger; producer wired into `URLSessionTransferEngine.emitProgress` |
| Dark and light, Dynamic Type XXL | `final/09`–`final/13` |
| Light theme + in-app appearance override | `final/{19,20,21}` — every token was already appearance-adaptive; this adds a `System/Light/Dark` picker and applies it at the root over the device setting |
| Whole test suite | `215 tests in 14 suites passed` |

## Stubbed

| Feature | Why | What it would take |
|---|---|---|
| Remote tab | Desktop pairing is a V1.2 feature; it renders an honest `ContentUnavailableView` rather than fake content | The pairing protocol, which does not exist yet on either side |
| `GoelCore` as the engine | `Package.swift` is macOS-only, links `libssh2`/`libcurl`/`libtorrent`, and four files construct `Foundation.Process` | Stage 1b of the segregation plan: iOS xcframeworks for libcurl + libssh2, then a third `TransferEngine` implementation behind the same protocol |
| SFTP / FTP / HLS sources | The iOS engine is `URLSession`-only | The same xcframework work; the seam already accepts them (`Download.kind`) |
| Push-updated Live Activities | Deliberately excluded — no push server | Nothing; this is the design |
| Share/File Provider extension | Out of scope for this milestone | A separate extension target |

## Blocked

| Task | The exact blocker | What was tried |
|---|---|---|
| Screenshot the Lock Screen | `simctl` has no command to lock the device | Built `WidgetGalleryView`, which instantiates the *real* widget views from `Shared/WidgetViews.swift` at exact WidgetKit dimensions on a Lock-Screen-like ground, including `.vibrant` rendering mode |
| Long-press the Dynamic Island | Not scriptable | Same gallery renders the expanded and stale presentations directly |
| Tap an App Intent button | Requires touching the Live Activity | `CommandFile` round-trip, concurrency and idempotency are unit-tested; the button-to-file path is not |
| Browse to `Goel°` in Files.app | Needs taps; `simctl openurl` raises an undismissable "Open in …?" confirmation | Verified on disk instead: files land in `<container>/Documents/Goel°/` with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` set |
| Suspend the process mid-transfer | The simulator does not really suspend apps | `enterBackground`/`enterForeground` and the checkpoint/adopt path are unit-tested; PRD §4.1's 4 GB / locked-for-an-hour / airplane-mode test needs a device |

## Deviations

- **`Active` keeps completed downloads for 10 minutes.** frame0 shows a verified download sitting
  under four in-flight ones under the *Active* filter. A strict reading of "active" excludes it,
  but a file that vanishes the instant it finishes reads as "where did it go?". Grace period, then
  it lives in Done.
- **Share is disabled until the file is complete, with a sentence saying so.** The mockup shows a
  fully saturated Share button mid-transfer. Sharing a 63 %-complete disk image is not a feature.
- **The detail screen hides the tab bar.** The mockup gives it the whole display; the segment bars
  and throughput chart are why anyone opens it.
- **`Maximum connections` is a stepper.** The mockup prints `6`. A number you cannot change is not
  a setting.
- **Settings has an Appearance picker the mockup does not.** The design reference is dark-only, but
  every colour token carried a light value from the start (`SharedTheme`), so this exposes the
  choice rather than inventing one: a `System / Light / Dark` segmented control that applies at the
  root via `preferredColorScheme`. `System` defers to the device; Light/Dark pin the app regardless.
- **Settings' Desktop row is honest.** `Paired with · Nothing yet` + `Coming in 1.2`, not the
  mockup's `vinit's Mac · Linked`. There is no pairing to show.
- **The Library subtitle is coarser than the queue's.** `412.3 MB · Verified · Today` on the shelf,
  `412.3 MB · SHA-256 verified · 2m ago` at the transfer desk — which is exactly what frame7 and
  frame0 respectively show.
- **The stale Live Activity says `updated 2 min, 3 sec ago`, the mockup says `updated 2 min ago`.**
  `Text(_:style: .relative)` is the only relative timestamp that keeps counting while the process
  is suspended, and it always renders two units. A frozen string on a suspended process would be a
  lie, so the extra unit stays.
- **The sparkline normalises to the window maximum.** The hand-drawn SVG in `visual.html` sweeps
  from low-left to high-right; real throughput at a steady 47 MB/s draws a nearly flat line, and
  that is the truthful picture.
- **Add-sheet detent is `.fraction(0.66)`, not `.medium`.** At `.medium` the "Start paused" row
  lands underneath the bottom button and reads as missing.
- **`NSAllowsArbitraryLoads` is in the app Info.plist.** Development-only, for
  `http://localhost:8099`. **This must be removed before any App Store submission.**
- **Three `#if DEBUG` deep links exist purely for the screenshot harness**: `goel://debug/…`,
  `goel://start?url=…`, and the `-uiTestingRoute` launch argument. None of them ship in a release
  build except `goel://debug`, which is also `#if DEBUG`-gated at the Settings entry point.

## Known bugs

1. **Library "Recent" shows one row; frame7 shows three.** Only `Blender-4.2-macOS-arm64.dmg` is
   `.completed` in the fixture set — frame7 depicts a later moment where keynote and nas-backup
   have also finished, which contradicts frame0 where both are mid-transfer. The app renders one
   coherent moment; the mockup renders two. Not a code bug, but the Library screen looks emptier
   than the design implies. Fix by adding two more completed fixtures under different names.
2. **The FASTEST widget's sparkline flattens on live data.** `SharedSnapshot` carries a point
   speed sample per download, not a series, so the widget has nothing to plot outside the preview
   fixture. Needs a small ring buffer in the snapshot.
3. **"Data used this month" only counts what the foreground engine sees.** The producer is wired
   into `emitProgress`, which does not run while the transfer is handed to the background
   `URLSession`. Cellular bytes moved while suspended are not counted.
4. **The Add sheet's link field truncates at the tail.** `https://releases.ubuntu.com/24.04.1/ubuntu…`
   hides the filename, which is the useful half. The mockup elides the middle.
5. **`UIPasteboard` prefill does not fire for a plain-text URL.** `pasteboardLink()` guards on
   `hasURLs`, which is false when the pasteboard holds only `public.utf8-plain-text` (which is what
   most apps write). The non-prompting fix is `detectPatterns(for: [.probableWebURL])`.
6. **Playback of the test fixture shows heavy compression artifacts in the simulator.** Confirmed
   *not* an app bug: the same artifacts appear on the complete, checksum-verified file, so it is
   the fixture's bitrate plus the simulator's software decoder.
7. **`simctl install` over a running app occasionally leaves the next launch without its launch
   arguments**, which silently selects the real engine and an empty queue. Terminate, sleep, then
   launch. Cost me two wrong screenshots.
8. **Six more views still use fixed-point type.** The detail screen was fixed in the final sweep, but
   `PlayerView`'s stat cells (`:656`), `LibraryView` (`:499,613`), `MediaGrid` (`:226,239`),
   `BufferScrubber` (`:220`) and `KindIcon` (`:152,159`) still call `.font(.system(size:))` on a raw
   `Theme.Typo` token with no `@ScaledMetric` in front of it — the same defect, less visible. They do
   not clip at XXXL, but they do not grow either.
9. **No memory-pressure measurement.** T16 asked for peak memory from the Xcode gauges; the run was
   driven entirely from the command line and no gauge was attached.

## Next

Ranked, with effort estimates.

1. **Run the PRD §4.1 background handoff on a real device** — 4 GB file, phone locked for an hour,
   airplane mode toggled mid-transfer. Everything else here is verified; this is the one load-
   bearing behaviour that a simulator physically cannot prove. **Half a day**, mostly waiting.
2. **Tap the App Intent buttons on a device** and confirm `openAppWhenRun = false` really keeps the
   app closed. **An hour**, if a device is provisioned.
3. **Give `SharedSnapshot` a speed ring buffer** so the FASTEST widget plots something real.
   **Two hours**, including the widget-timeline budget check.
4. **Count cellular bytes from the background session too** — `URLSessionTaskDelegate` reports
   `didSendBodyData`/`didWriteData` per task; route those through the same ledger.
   **Two hours**.
5. **Finish the Dynamic Type sweep** — the six views in Known bug 8, same `@ScaledMetric(relativeTo:)`
   pattern the detail screen now uses. **Two hours**, mechanical.
6. **Two more completed fixtures** so the Library and its media grid look like frame7. **An hour.**
7. **Remove `NSAllowsArbitraryLoads`** and point the test server at HTTPS with a local trust anchor
   before any submission build. **Two hours.**
8. **Stage 1b of the segregation plan** — libcurl and libssh2 iOS xcframeworks, then `GoelCore`
   behind the existing `TransferEngine` protocol, which unlocks SFTP and FTP on the phone.
   **Several days**; this is the real next milestone, not a cleanup item.
