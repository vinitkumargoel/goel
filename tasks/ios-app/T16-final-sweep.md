# T16 — Final sweep and report

**Goal:** leave the tree in a state the user can pick up in thirty seconds at 7am.

## 1. Full visual sweep

Fresh state, then walk every screen and shoot it:

```bash
xcrun simctl uninstall "$SIM" dev.goel.ios
./Scripts/ios/sim.sh build && ./Scripts/ios/sim.sh run
xcrun simctl status_bar "$SIM" override --time "9:41" \
  --batteryState charged --batteryLevel 100 --cellularBars 4 --dataNetwork wifi
```

Shoot into `tasks/ios-app/shots/final/`: queue, detail, add sheet, player, library,
settings, widget gallery, home-screen widgets, Dynamic Island (compact + expanded + stale),
Files app.

**Read every one.** For each, note in the report whether it matches its `visual.html` frame,
and if not, exactly how it differs.

Then repeat the two most important screens (queue, detail) in **light appearance** and at
**Dynamic Type XXL**, and confirm nothing clips or becomes illegible.

## 2. Full test run

```bash
./Scripts/ios/sim.sh test
```

Every test green, or the failure explained in the report. Do not delete or `.skip` a failing
test to get a green run — a disabled test in the report reads as a lie by morning.

## 3. Real-download soak

With `range-server.py --throttle 20000000` and a 500 MB fixture: queue three downloads at
once, let them run to completion, and verify **all three checksums**. Note peak memory from
Xcode's gauges or `xcrun simctl spawn "$SIM" log` if you can get it.

## 4. Write `tasks/ios-app/REPORT.md`

Structure it exactly like this — the user reads it first and is not going to dig:

```
# Goel° iOS — overnight build report

## TL;DR
One paragraph. What works, what doesn't, what to look at first.

## Run it
Exact commands, copy-pasteable.

## Screens        (table: screen | shot path | matches mockup? | notes)
## Works          (feature | evidence — a test name or a screenshot)
## Stubbed        (feature | why | what it would take)
## Blocked        (task | the exact error | what you tried)
## Deviations     (from visual.html or the PRD, each with reasoning)
## Known bugs     (be exhaustive and specific — this is the most useful section)
## Next           (ranked, with your estimate of effort)
```

## 5. Leave it clean

- Working tree committed on `ios-app-impl`. **Not pushed.**
- `git log --oneline main..ios-app-impl` reads as a clean per-task history.
- No stray build artifacts committed — `apps/ios/.build/`, `*.xcodeproj` (xcodegen
  regenerates it), and `Scripts/ios/fixtures/` all belong in `.gitignore`.
- Kill the range server.
- `LEDGER.md` final state accurate.

## The standard for the report

Understate rather than overstate. If T10's player only works via the polling fallback, say
that. If a screenshot does not really match the mockup, say which part. The user will open
the app within a minute of reading this — anything optimistic will be caught immediately and
will make the rest of the report untrustworthy.

`git commit -m "ios(T16): final sweep, screenshots, and report"`
