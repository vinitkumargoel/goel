# T15 — App Intents: control without launching

**Goal:** PRD §6.5 — *"Pausing a 4 GB download from the Dynamic Island without ever
opening the app is the single most demo-able thing in this product."*

Small task, outsized payoff. The Live Activity buttons from T13 are inert until this lands.

## Build

**`Shared/DownloadIntents.swift`** — member of both targets.

```
struct PauseDownloadIntent: AppIntent   { static let title: LocalizedStringResource = "Pause Download"  }
struct ResumeDownloadIntent: AppIntent  { ... }
struct CancelDownloadIntent: AppIntent  { ... }
struct PauseAllIntent: AppIntent        { ... }
```

Each carries `@Parameter var downloadID: String` and sets
**`static var openAppWhenRun = false`** — this is the entire point. If it is `true` the
demo is dead.

An intent runs **in the widget extension's process**, not the app's. It cannot reach
`DownloadStore` in memory. So:

1. The intent writes a **command record** to a file in the App Group container —
   `commands.json`, an append-only array of `{id, action, issuedAt}`.
2. It **immediately** updates `SharedSnapshot` optimistically so the Live Activity and
   widgets reflect the new state without waiting for the app. The PRD requires the queue to
   reflect it *immediately*.
3. It returns `.result()`.
4. The app drains the command file on launch, on foreground, and on every background
   `URLSession` wake, applies each command to the real engine, and truncates the file.
5. Commands are **idempotent** and keyed by `issuedAt` — draining twice must not
   double-apply. Discard commands older than ~1 hour.

Use a coordinated write (`NSFileCoordinator`) or an atomic replace; two processes touch
this file.

**Also expose to Shortcuts/Siri** — it is nearly free once the intents exist:
- `AddDownloadIntent(url:)` with `openAppWhenRun = false`
- An `AppShortcutsProvider` with a couple of phrases (`"Pause downloads in Goel"`).

## Exit criteria

- Unit tests (this is the gate):
  - Issuing a pause command writes a well-formed record.
  - Draining applies it and truncates.
  - Draining the same file twice applies once.
  - A stale command (>1h) is discarded.
  - The optimistic snapshot update reflects the paused state.
- Live: start a download, background the app, tap **Pause** in the Dynamic Island expanded
  view, screenshot → the activity shows paused. Foreground the app → the queue shows paused
  and the transfer has actually stopped. Screenshot both: `T15-intent-paused.png`.
- `git commit -m "ios(T15): app intents for pause/resume/cancel from live activity"`

## Notes

- If tapping a Live Activity button launches the app, `openAppWhenRun` is `true` somewhere,
  or the intent failed to resolve and iOS fell back to opening the app.
- Do not try to share the engine actor across processes. The command file *is* the IPC.
  Anything cleverer will fail in ways that only show up on device.
