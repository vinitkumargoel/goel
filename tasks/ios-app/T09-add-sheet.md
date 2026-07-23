# T09 — Add sheet + metadata probe

**Goal:** frame 3 of `visual.html`. The thesis: **resolve the metadata before the user
commits.** Name, exact size, type, and resumability are known *before* the tap.

## Build

**`Goel/Engine/MetadataProbe.swift`** — thin wrapper over `TransferEngine.probe`, with:
- Debounce ~400ms after typing stops.
- Cancellation of the in-flight probe when the URL changes.
- A 5s timeout. On timeout or failure, the sheet still works — it just shows
  `Size: Unknown` and `Resume: Unsupported`. **Never block Add on a failed probe.**

**`Features/Add/AddSheet.swift`** — presented as a `.sheet` with
`.presentationDetents([.medium, .large])` and a visible grabber.

Rows, matching the mockup:

| Field | Behavior |
|---|---|
| Link | `TextField`, `.keyboardType(.URL)`, `.autocapitalization(.never)`, monospaced 12.5pt. Prefilled from the pasteboard if it holds a valid URL. |
| Name | Editable; defaults to the probed filename |
| Size | Read-only, from the probe; `Unknown` when absent |
| Type | Read-only — `Disk Image · resumable` / `Video · streamable` / `Archive` |
| Save to | Navigates to a folder picker inside the container |
| Wi-Fi only | `Toggle`, default **on** |
| Start paused | `Toggle`, default off |

- Header: `Cancel` (leading) / `Add Download` (title) / `Add` (trailing, ember, **disabled
  until the URL parses**).
- A filled ember `Add Download` button at the bottom.
- While probing: an inline `ProgressView` on the Size row, not a blocking overlay.

**Validation, done honestly:**
- Reject non-`http`/`https` schemes with a clear inline message. (`file://` must not be
  accepted — the desktop facade rejects it and so does this.)
- Reject an unparseable URL.
- If the probe says `supportsResume == false`, show it plainly on the Type row before the
  user commits. PRD §4.1: *"we say so honestly up front rather than failing at 99%."*

**Entry points:** the `+` in the queue nav bar, and a URL-scheme / Share-Sheet handoff if
it is cheap. Do not build a Share Extension target tonight.

## Exit criteria

- Paste `http://localhost:8099/test-200mb.bin` with `range-server.py` running → within a
  second the sheet shows `200 MB`, `resumable`, and the filename. That is the whole feature
  working end to end.
- Tap Add → the download appears in the queue and starts.
- With `--no-ranges`, the sheet says not resumable **before** you tap Add.
- `Scripts/ios/sim.sh shot T09-add-sheet`, **Read it**, compare to frame 3.
- `git commit -m "ios(T09): add sheet with pre-commit metadata probe"`

## Notes

- The sheet must be usable with the keyboard up. Verify the Add button is not covered —
  screenshot with the field focused.
- Do not auto-add from the pasteboard. Prefill the field and let the user decide;
  silently queueing something they copied is hostile.
