# T06 — Background transfer handoff

**Goal:** implement the Handoff model from `docs/PRD-iOS.md` §4.1 — read that section
first, in full. The PRD calls this *"the highest-risk engineering work in the project."*
Treat it that way.

## The model

| App state | Strategy |
|---|---|
| Foreground | Full segmented multi-connection (T05) |
| Entering background | Checkpoint the cursor, cancel segments, **re-issue the remainder as a single background `URLSession` task** with `Range:` from the cursor + `If-Range:` validator |
| Returning to foreground | Adopt what the background task completed, resume segmentation for the remainder |

The trade is deliberate: slower in the background, but it **finishes**.

## Build

**`Goel/Engine/BackgroundCoordinator.swift`**

- A background `URLSessionConfiguration.background(withIdentifier: "dev.goel.ios.bg")`,
  `isDiscretionary = false`, `sessionSendsLaunchEvents = true`.
- **Exactly one** background session for the app's lifetime. Creating a second with the
  same identifier throws at runtime.
- Implement `handleEventsForBackgroundURLSession` in the app delegate adaptor and store the
  completion handler; call it on `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
  Without this, iOS terminates the app before it can persist state.

**The state machine** — put it in its own type, `HandoffState`, with **no `URLSession`
dependency**, so it is unit-testable:

```
enum TransferStrategy { case segmented, backgroundSingle, suspended }

func strategy(for phase: ScenePhase, download: Download) -> TransferStrategy
func rangeForResume(_ d: Download) -> ClosedRange<Int64>?   // contiguous cursor only
func canAdoptBackgroundResult(_ d: Download, validator: String?) -> Bool
```

**The critical correctness rule:** the background task may only resume from the
**contiguous prefix** of completed bytes, not the total received. With 6 segments at
100/78/64/57/41/22%, the contiguous prefix ends where segment 1 ends — everything after is
a hole. Resuming from `receivedBytes` would silently corrupt the file. This is the single
highest-risk line of code in the task; write the test first.

**Transitions:**
- `.active → .background`: checkpoint every segment cursor to disk, cancel segment tasks,
  compute the contiguous prefix, start one background task for `[prefix, total]`.
- `.background → .active`: adopt bytes the background task wrote, re-probe the validator,
  and if it still matches, re-segment the remainder. If it changed, fail loudly with
  `remoteFileChanged` — never merge across a changed file.
- Airplane mode / connection loss: background `URLSession` retries by itself. Do not
  duplicate that logic; do not cancel on the first error.

## Exit criteria

Unit tests on `HandoffState`, all passing — this is the gate, **not** simulator observation:
- Contiguous prefix with a gapped segment set returns the prefix, not the sum.
- Contiguous prefix with all segments complete returns the total.
- `canAdoptBackgroundResult` is `false` when the ETag changed, `true` when it matches,
  and `false` when the validator is absent on a previously-validated download.
- `Range` header from a resume cursor is correctly inclusive.
- A `.background → .active → .background` cycle does not double-count bytes.

Then, best-effort on the simulator: start a download, `xcrun simctl launch "$SIM"
com.apple.springboard`, wait 30s, foreground it, confirm progress advanced and the
checksum still matches at completion.

`git commit -m "ios(T06): foreground/background transfer handoff"`

## Notes

- **The simulator does not truly suspend apps.** It will not reproduce real background
  behavior, and a green simulator run proves very little here. Say so in `REPORT.md`. The
  PRD's real acceptance test — *4 GB, backgrounded at 10%, locked 1 hour, airplane mode
  toggled* — requires a physical device and is **not** tonight's work.
- Do not attempt to make background `URLSession` run six parallel tasks. It is
  system-managed and out-of-process; that is the whole reason the handoff exists.
- If this task defeats you, leaving T05's foreground engine intact and marking T06
  `BLOCKED` is a legitimate outcome. Do not damage T05 trying.
