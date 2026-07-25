# CONVENTIONS — the loop, the layout, the rules

Everything in this file is verified working on this machine as of the session that wrote it.

## Environment (verified)

| | |
|---|---|
| Xcode | 26.6 (17F113) |
| SDK | `iphonesimulator26.5` |
| Swift | 6.3.3 |
| Simulator | **iPhone 17 · iOS 26.5 · `BC332A27-A788-413C-910B-7686447B73F1` · already booted** |
| xcodegen | 2.44.1 (`/opt/homebrew/bin/xcodegen`) |

Not installed, do not rely on: `tuist`, `swiftlint`, `swiftformat`, `xcbeautify`.

Deployment target: **iOS 18.0**. Everything needed (ActivityKit, interactive widgets,
accessory families, App Intents) is available at 18.0 and the only sims present are 18.0 and 26.x.

---

## Build → Screenshot (memorize this)

Put this in `Scripts/ios/sim.sh` in T01 and use it for the rest of the night.

```bash
SIM=BC332A27-A788-413C-910B-7686447B73F1
APP_ID=dev.goel.ios
PROJ=apps/ios/Goel.xcodeproj
DD=apps/ios/.build
SHOTS=tasks/ios-app/shots

# 1. regenerate project after ANY change to project.yml or new source dirs
(cd apps/ios && xcodegen generate)

# 2. build  (CODE_SIGNING_ALLOWED=NO — simulator needs no signing)
xcodebuild -project "$PROJ" -scheme Goel \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -40

# 3. install + launch
APP="$DD/Build/Products/Debug-iphonesimulator/Goel.app"
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$APP_ID"

# 4. screenshot, then LOOK AT IT with the Read tool
xcrun simctl io "$SIM" screenshot "$SHOTS/<name>.png"
```

**Then `Read` the PNG.** The Read tool renders images. This is the whole point — you are
not building blind. Compare against the corresponding frame in `visual.html`.

### Screenshot hygiene

Pin the status bar once per session so shots match the mockup's `9:41`:

```bash
xcrun simctl status_bar "$SIM" override --time "9:41" \
  --batteryState charged --batteryLevel 100 --cellularBars 4 --dataNetwork wifi
```

Dark mode (the app's designed identity — most frames in `visual.html` are dark):
```bash
xcrun simctl ui "$SIM" appearance dark    # or: light
```

### Useful simctl (all verified)

```bash
xcrun simctl launch "$SIM" com.apple.springboard   # background the app / go to Home
xcrun simctl terminate "$SIM" "$APP_ID"
xcrun simctl uninstall "$SIM" "$APP_ID"            # when state gets dirty
xcrun simctl spawn "$SIM" log stream --predicate 'subsystem == "dev.goel.ios"' --style compact
xcrun simctl get_app_container "$SIM" "$APP_ID" data
xcrun simctl get_app_container "$SIM" "$APP_ID" groups   # App Group path
```

### Tests

```bash
xcodebuild -project "$PROJ" -scheme Goel \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -40
```

---

## File layout — use these exact paths

Later tasks import from these paths. Do not reorganize.

```
apps/ios/
  project.yml                        # xcodegen spec, single source of truth
  Goel/
    GoelApp.swift                    # @main
    Info.plist
    Goel.entitlements                # App Group
    DesignSystem/
      Theme.swift                    # colors + metrics from visual.html   (T02)
      Formatters.swift               # bytes / speed / ETA / duration      (T02)
    Model/
      Download.swift                 # Download, Status, Kind, Segment     (T03)
      DownloadStore.swift            # @Observable, App Group persisted    (T03)
    Engine/
      TransferEngine.swift           # the protocol — the seam             (T04)
      PreviewTransferEngine.swift    # deterministic fake                  (T04)
      URLSessionTransferEngine.swift # real segmented HTTP                 (T05)
      BackgroundCoordinator.swift    # foreground↔background handoff       (T06)
      MetadataProbe.swift            # HEAD / Range probe                  (T09)
    Features/
      Queue/    QueueView.swift  DownloadRow.swift                         (T07)
      Detail/   DetailView.swift SegmentBars.swift Sparkline.swift         (T08)
      Add/      AddSheet.swift                                             (T09)
      Player/   PlayerView.swift                                           (T10)
      Library/  LibraryView.swift                                          (T11)
      Settings/ SettingsView.swift                                         (T12)
      Debug/    WidgetGalleryView.swift                                    (T14)
    RootView.swift                   # TabView                             (T07)
  Shared/                            # membership in BOTH targets
    DownloadActivityAttributes.swift # ActivityKit attributes              (T13)
    SharedSnapshot.swift             # App Group JSON the widgets read     (T03)
    SharedTheme.swift                # colors usable from the extension    (T02)
    DownloadIntents.swift            # App Intents                         (T15)
  GoelWidgets/                       # widget extension target
    GoelWidgetsBundle.swift
    LiveActivityWidget.swift         # lock screen + Dynamic Island        (T13)
    AccessoryWidgets.swift           # circular / rectangular / inline     (T14)
    HomeWidgets.swift                # small / medium                      (T14)
    Info.plist
    GoelWidgets.entitlements
  GoelTests/                         # unit tests (Swift Testing)
Scripts/ios/
  sim.sh                             # the loop above                      (T01)
  range-server.py                    # Range-capable local HTTP server     (T05)
tasks/ios-app/
  shots/                             # every screenshot you take
```

**Identifiers** (used verbatim in entitlements, Info.plist, and code):

| | |
|---|---|
| App bundle ID | `dev.goel.ios` |
| Widget bundle ID | `dev.goel.ios.widgets` |
| App Group | `group.dev.goel.ios` |
| Log subsystem | `dev.goel.ios` |

---

## Code rules

- **SwiftUI only.** `@Observable` (Observation framework), not `ObservableObject`.
- **Swift 6 strict concurrency.** `TransferEngine` implementations are `actor`s; views are `@MainActor`.
- **No force unwraps** outside tests. No `try!`. No `fatalError` on a recoverable path.
- **No third-party packages.** Zero SPM dependencies in `apps/ios/project.yml`. Everything
  needed is in the SDK.
- **Never hardcode a color literal in a view.** All color and metric values come from
  `Theme.swift`, which is where `visual.html`'s values live.
- **Formatters are centralized.** `1.4 GB`, `48.2 MB/s`, `44s left` — one implementation,
  unit-tested, used everywhere. Byte counts use `.file` style (base 10, matching the mockup).
- **`font-variant-numeric: tabular-nums` equivalent**: use `.monospacedDigit()` on every
  number that updates live. The mockup relies on this — figures must not jitter.

## Accessibility (not optional — it is in the PRD)

Every task that ships UI also ships:
- A meaningful `.accessibilityLabel` on every icon-only control.
- Progress conveyed as `.accessibilityValue("63 percent")`, never color alone.
- Dynamic Type: no fixed `.frame(height:)` on text rows; verify at XXL.
- Minimum 44×44pt hit targets.

---

## When something does not work

Order of attack, then move on:
1. Read the actual `xcodebuild` error. Not the summary — scroll to the first `error:`.
2. `xcodegen generate` again (stale project is the #1 cause of "file not found").
3. `rm -rf apps/ios/.build` and rebuild once.
4. `xcrun simctl uninstall "$SIM" dev.goel.ios` if state looks corrupt.
5. Still broken after ~20 min → revert the task, log `BLOCKED` in `LEDGER.md`, next task.

### Known simulator limits — do not fight these

- **Background `URLSession` does not truly suspend on the simulator.** The simulator will
  not reproduce real background-transfer behavior. Verify T06 with **unit tests on the
  handoff state machine**, not by observing the simulator. Note it in `REPORT.md`.
- **The Lock Screen cannot be triggered from `simctl`.** There is no lock command. This is
  why T14 builds an in-app **Widget Gallery** that renders the real widget views at exact
  accessory dimensions — that is your verification surface for lock-screen widgets.
- **Dynamic Island** *is* visible on iPhone 17. Background the app with
  `xcrun simctl launch "$SIM" com.apple.springboard`, then screenshot.
- **App Groups work on the simulator** without a paid team. If
  `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil`, fall back to
  `.applicationSupportDirectory`, log a warning, and keep going — do not block on it.
