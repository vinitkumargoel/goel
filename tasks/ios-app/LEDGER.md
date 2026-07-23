# LEDGER — update this as you go, not at the end

This is the first thing the user reads when they wake up. Keep it current.

Status values: `TODO` · `WIP` · `DONE` · `PARTIAL` · `BLOCKED`

| # | Task | Status | Commit | Screenshot | Notes |
|---|---|---|---|---|---|
| T01 | Xcode project scaffold | DONE | `36c9d07` | `shots/T01-hello.png` | App + widget ext build & launch; App Group resolves on sim |
| T02 | Design system | WIP | | | |
| T03 | Model + store | WIP | | | |
| T04 | TransferEngine seam | WIP | | | |
| T05 | URLSession engine | WIP | | | harness (`range-server.py`) started first |
| T06 | Background handoff | TODO | | | |
| T07 | Queue screen | TODO | | | |
| T08 | Detail screen | TODO | | | |
| T09 | Add sheet | TODO | | | |
| T10 | Player | TODO | | | |
| T11 | Library + Files | TODO | | | |
| T12 | Settings | TODO | | | |
| T13 | Live Activity | TODO | | | |
| T14 | Widgets | TODO | | | |
| T15 | App Intents | TODO | | | |
| T16 | Final sweep | TODO | | | |

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

## Dead ends — do not retry

_(none yet)_
