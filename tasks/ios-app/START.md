# START HERE — Goel° for iOS, autonomous build

You are the implementation agent. The user is asleep. Nobody will answer questions.
Your job: **ship a working, visually verified iOS app by morning.**

Read this file completely, then `CONVENTIONS.md`, then start at `T01`.

---

## The one rule that matters

**You can see your own work.** The simulator is booted. After every UI task you build,
install, launch, screenshot, and then `Read` the PNG — the Read tool renders images.
If it looks wrong, fix it and shoot again. Do not mark a UI task done on a green build
alone. Look at it.

The full loop is in `CONVENTIONS.md § Build → Screenshot`.

---

## What you are building

A native iOS download manager. Two source documents, both authoritative:

| Document | Role |
|---|---|
| `docs/PRD-iOS.md` | **What and why.** Scope, the two defining problems, glanceable-surface rules, risks. |
| `visual.html` (repo root) | **Exactly what it looks like.** 9 screens at true 1:1 with real iOS metrics. |

`visual.html` is not inspiration, it is the spec. Open it and read the CSS — the colors,
the point values, the type scale, and the `figcaption .spec` blocks are the numbers you
implement against. Where the PRD and the mockup disagree, the mockup wins on appearance
and the PRD wins on behavior.

---

## The engine decision — read this before you touch `Package.swift`

`GoelCore` is a mature Swift transfer engine in this repo. **It does not compile for iOS
and you are not going to make it.** Verified facts:

- `Package.swift` declares `platforms: [.macOS(.v14)]` only.
- `SSHBridge` links `-L/opt/homebrew/opt/libssh2/lib -lssh2` — a Homebrew path.
- `CurlBridge` links `.linkedLibrary("curl")`; `TorrentBridge` links `-ltorrent-rasterbar -lssl -lcrypto`.
- Five files under `Sources/GoelCore/` construct `Foundation.Process`, which does not exist on iOS.

Building libcurl and libssh2 as iOS xcframeworks is a real, separate milestone
(`docs/PRD-iOS.md` → M0; the plan calls it Stage 1b). It is **out of scope tonight** and
attempting it will burn the whole night.

**Instead:** the app talks to a `TransferEngine` protocol (T04). Tonight it is backed by
`URLSessionTransferEngine` (T05/T06) — real HTTP, real segmentation, real background
transfer, no C dependencies. `GoelCore` becomes a third implementation later, behind the
identical seam.

Do not add an iOS platform to the root `Package.swift`. Do not link `GoelCore` from the
app target. The iOS app is a **standalone Xcode project** at `apps/ios/`.

---

## Task order

Strictly linear. Each task's exit criteria are machine-checkable. Do not skip ahead;
later tasks assume earlier files exist at exact paths.

| # | Task | Gate |
|---|---|---|
| T01 | Xcode project scaffold (app + widget extension) | App launches on the simulator |
| T02 | Design system — tokens lifted from `visual.html` | Swatch screen screenshots correctly |
| T03 | Domain model + App Group store | Unit tests pass, state survives relaunch |
| T04 | `TransferEngine` protocol + `PreviewTransferEngine` | Previews render deterministic state |
| T05 | `URLSessionTransferEngine` — segmented HTTP | Real 200 MB file downloads from local server |
| T06 | Background transfer handoff (**PRD §4.1**) | Handoff unit tests pass |
| T07 | Queue screen | Screenshot matches `visual.html` frame 1 |
| T08 | Detail screen — parallel segments, sparkline | Screenshot matches frame 2 |
| T09 | Add sheet + metadata probe | Screenshot matches frame 3 |
| T10 | Player — play while downloading | Video plays at <30% complete |
| T11 | Library + Files app integration | Files.app shows downloads |
| T12 | Settings | Screenshot matches frame 9 |
| T13 | Live Activity + Dynamic Island, all 4 states | Island screenshot from SpringBoard |
| T14 | Widgets — accessory, home screen, debug gallery | Gallery screenshot shows all 6 |
| T15 | App Intents — pause/cancel without launching | Intent unit tests pass |
| T16 | Full sweep — all screens, all tests, write report | `REPORT.md` exists |

**T01 through T09 are the floor.** If you get exactly that far and everything is solid,
that is a good night's work. Do not sacrifice quality in T05–T08 to reach T16.

---

## Ground rules

1. **Never leave the build broken.** Every task ends on a green `xcodebuild`. If you
   cannot fix a break within ~20 minutes, `git checkout` the task's changes, record the
   failure in `LEDGER.md`, and move to the next task.

2. **Commit after every task**, on a dedicated branch. First thing you do:
   ```
   git checkout -b ios-app-impl
   ```
   Then per task: `git add -A && git commit -m "ios(T0N): <what>"`.
   **Never push. Never touch `main` or `ios-app`.**

3. **Never modify** `Package.swift`, `Sources/`, `Tests/`, or `docs/PRD-iOS.md`.
   All new code goes under `apps/ios/`. Test harness scripts go under `Scripts/ios/`.

4. **Fail open, never stall.** If a task is genuinely blocked (a simulator capability that
   does not exist, an entitlement that will not provision), write `BLOCKED` plus the exact
   error into `LEDGER.md`, implement whatever portion *is* possible, and continue. A
   blocked task is fine. A stalled night is not.

5. **Update `LEDGER.md` as you go**, not at the end. It is the first thing the user reads.

6. **No placeholder UI.** No lorem, no "TODO: design this", no gray boxes standing in for
   screens. Use the real content from `visual.html` — the real filenames, real byte counts,
   real speeds. If a feature is not implemented, do not ship a fake screen for it.

7. **Swift 6 language mode, strict concurrency.** Warnings are acceptable; errors are not.

---

## When you are done

Write `tasks/ios-app/REPORT.md`:
- What works, with the screenshot path for each screen.
- What is stubbed or blocked, and precisely why.
- Every deviation from `visual.html` or the PRD, with your reasoning.
- The exact commands to build and run it.
- What you would do next.

Be accurate. If something does not work, say so plainly — an honest report is worth far
more to the user at 7am than an optimistic one.
