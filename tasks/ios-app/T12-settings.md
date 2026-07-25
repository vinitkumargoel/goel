# T12 — Settings

**Goal:** frame 9 of `visual.html`. Real engine capability, phone vocabulary.

## Build

**`Features/Settings/SettingsView.swift`** — a grouped inset `Form`, sections exactly as
the mockup:

**Transfers**
- Traffic profile → push to a picker: Conservative / Balanced / Aggressive. Wire it to a
  real connection-count and chunk-size change in `URLSessionTransferEngine`, not a stored
  value nothing reads.
- Maximum connections → `Stepper`, 1…8, default 6.
- Speed limit → Off / 1 / 5 / 10 / 25 MB/s. **Actually enforce it** with a token bucket in
  the engine. A setting that does nothing is worse than no setting.

**Cellular**
- Download over cellular — default **off**.
- Finish on Wi-Fi — default on.
- Data used this month — a real counter, persisted, reset monthly.
- Enforcement lives in the engine via `NWPathMonitor`: when cellular is disallowed and the
  path is cellular, downloads move to `.waitingForWiFi` rather than failing. That status
  already exists in T03 and is shown in T07.

**Files**
- Show in Files app (informational, links to the system setting if it is off)
- Verify checksums — on by default
- Storage used → computed size of the container, with a "Clear completed" destructive action
  behind a confirmation.

**Desktop**
- Paired with → `vinit's Mac` + a green `Linked` pill. **This is a placeholder for the V1.2
  continuity feature.** Render it as a real-looking but clearly non-functional row that
  states pairing is coming — do not fake a working pairing flow.

**About** — version, build, an acknowledgements link.

Settings persist through `@AppStorage` or the store; every one is read by something.

## Exit criteria

- `Scripts/ios/sim.sh shot T12-settings`, **Read it**, compare to frame 9. Check grouped
  inset radius 12, 16pt gutters, native 51×31 switches, the green pill.
- Set Maximum connections to 2, start a download, and confirm the detail screen shows
  **2** segment bars. That proves the setting is wired, not decorative.
- Toggle cellular off → engine reports `.waitingForWiFi` when on a cellular path
  (unit-test the policy function; the simulator is always "Wi-Fi").
- `git commit -m "ios(T12): settings wired to engine behavior"`

## Notes

- Desktop-only concepts stay out: watch folders, post-download scripts, the remote server,
  torrent settings. The mockup's caption is explicit about this and it is a deliberate
  product position, not an oversight.
