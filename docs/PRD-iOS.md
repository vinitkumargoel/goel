# PRD — Goel° for iOS

**Status:** Draft for review · **Owner:** Vinit Kumar Goel · **Phase:** post-Stage-1a (engine segregated; iOS engine not yet compiling)

---

## 1. The one-line bet

**Every download manager on iOS is a toy, because iOS makes the two defining features impossible: downloads that keep running, and a place to put files.** Goel° ships a real transfer engine — the same one that runs on the desktop — and solves those two problems properly. That is the entire product.

If we ship a beautiful list UI on top of a foreground-only downloader, we have built what already exists and failed. The bar is: **you start a 4 GB download, lock your phone, come back an hour later, and it is done.**

---

## 2. Why this can win

We are not starting from a prototype. `GoelCore` is a mature, tested engine with capabilities that no App Store download manager has:

| Engine capability | Why it matters on mobile |
|---|---|
| **Segmented multi-connection HTTP** with mirror failover | Visibly faster than Safari on the same link — the demo that sells the app |
| **Durable resume** (`resumeData`: byte cursor + ETag/Last-Modified validators) | Survives app kill, network switch, reboot — the foundation for everything in §4 |
| **Sequential download** (`sequentialDownload`) | **Play media while it is still downloading** — the single most loved feature we can ship |
| **Checksum verification** (`expectedChecksum`) | "This file is intact" — trust, especially over flaky mobile networks |
| **Per-file selection** (`FilePriority.skip`) in multi-file transfers | Grab one file out of an archive set without the rest |
| **HTTP/FTP/SFTP/HLS** in one queue | SFTP alone is a category — no consumer iOS app does this well |
| **Export/import envelope**, remote-control portal | Desktop ↔ phone continuity (§6.4) — a genuine moat |
| **Traffic profiles, per-task caps, scheduling** | "Don't burn my cellular data; finish it on WiFi tonight" |

The engine is done. **This PRD is about the 20% that is iOS-specific and the 100% of the experience.**

---

## 3. Users & jobs

| Persona | Job to be done | Today's pain |
|---|---|---|
| **The media hoarder** (primary) | Pull large files/archives to my phone and actually watch/read them offline | Safari downloads die when backgrounded; no resume; Files is clumsy |
| **The power user with a NAS/server** | Move files off my SFTP box to my phone | No good SFTP transfer client; FTP apps are abandonware |
| **The desktop Goel° user** (wedge) | Continue on my phone what I started on my Mac | No continuity exists at all |
| **The commuter** | Queue on cellular, let it finish on WiFi, watch on the train | Manual, error-prone |

**Primary job:** *"Get this large file onto my phone, reliably, without babysitting it, and let me use it the moment it's usable."*

---

## 4. The two problems that define the product

Everything else is table stakes. These two decide whether we ship something great or something pointless.

### 4.1 Background transfer — the existential problem

**The conflict, stated honestly:** our speed advantage comes from custom segmented multi-connection transfers (`SegmentedTransfer`, libcurl). iOS only guarantees background completion via **`URLSession` background configuration**, which is a *system-managed, out-of-process* downloader that will not run our segmentation logic. **These are architecturally incompatible.** This is already flagged in the Phase-1 plan; W2 defined the `BackgroundTransfer` seam but deliberately left it unimplemented — *"no conformer yet."*

**Proposed resolution — the Handoff model.** We already persist exactly what a handoff requires: a byte-range cursor plus `ETag`/`Last-Modified` validators.

| App state | Transfer strategy |
|---|---|
| **Foreground** | Full segmented multi-connection (our speed advantage, on display) |
| **Entering background** | Checkpoint `resumeData`, cancel segments, **re-issue the remainder as a single background `URLSession` task** with a `Range:` header from the cursor + `If-Range:` validator |
| **Returning to foreground** | Adopt whatever the background task completed, resume segmentation for the remainder |

**Consequences we accept:** downloads get slower in the background (single stream) but they **finish**. That trade is unambiguously correct — a fast download that dies is worth nothing.

**Requirements this creates:**
- `BackgroundTransfer` port must get a real iOS conformer (`URLSessionDownloadTask`, background config, `handleEventsForBackgroundURLSession`)
- The engine must tolerate a transfer that changes strategy mid-flight without corrupting the file — **the highest-risk engineering work in the project**
- Server must support ranges; when it doesn't (`DownloadError.rangeNotSupported`), we say so honestly up front rather than failing at 99%

**Non-negotiable acceptance test:** *4 GB file, app backgrounded at 10%, phone locked 1 hour, airplane mode toggled once → download completes, checksum verifies.* **If this test does not pass, we do not ship.**

> **Open risk:** background `URLSession` gives no wall-clock guarantee; the system may defer on low battery. We cannot promise "always." We can promise "resumes automatically and never loses progress." Marketing must not overpromise here.

### 4.2 There is no filesystem — make Files the feature

Desktop Goel° writes to arbitrary absolute paths. On iOS that is illegal; the app has a container.

**Position: don't fight it — make Files integration a headline feature.**

- Downloads land in the app container, browsable in a first-class in-app library
- **Full File Provider extension** so Goel° appears in the Files app — content is *there*, not trapped
- Explicit "Save to…" / "Move to iCloud Drive" via `UIDocumentPicker`
- Share Sheet **out** (send the finished file anywhere)

The W2 `FileStore` port is the seam; iOS gets a container-scoped adapter with security-scoped bookmarks. `PathSafety.isContained` remains the choke point.

---

## 5. Scope

### V1 — "It actually finishes" (App Store launch)

| Area | Included |
|---|---|
| Protocols | **HTTP/HTTPS** (segmented + background handoff), **HLS** (VOD → local file) |
| Adding | Share Sheet extension, clipboard detection, in-app URL box, **`.torrent`/magnet excluded** (§8.1) |
| Queue | Pause/resume/retry/remove, reorder, concurrent-limit, per-task + global speed caps |
| Reliability | Durable resume, auto-retry, mirror failover, checksum verification |
| Files | In-app library, **File Provider extension**, Save-to/Share-out, QuickLook preview |
| Media | **Play while downloading** (sequential), background audio, AirPlay |
| Smart | WiFi-only toggle, "finish on WiFi" deferral, scheduled start |
| **Glanceable** | **Live Activity (Lock Screen + Dynamic Island), Lock Screen accessory widgets, Home Screen widget, StandBy — with pause/resume inline** (§6.5) |
| Polish | Notifications on complete/fail, haptics, sounds |

### V1.1 — "Power"
SFTP + FTP (needs libssh2 xcframework hardening), per-file selection UI for multi-file transfers, tags/notes/search, history, Shortcuts/App Intents, iPad-optimized layout.

### V1.2 — "Continuity" (the moat)
Desktop pairing via the existing remote portal + `exportEnvelope`/`importEnvelope`: see the Mac queue on the phone, push a download either direction, hand off mid-transfer.

### Explicitly out of V1
BitTorrent (§8.1) · the remote-control *server* (phone as server makes no sense) · post-download shell scripts (impossible + pointless on iOS) · antivirus scanning · watch folders · network-interface aggregation (no multi-adapter bonding on iOS) · Android (separate plan, gated on Stage 0).

---

## 6. Experience requirements

The engine is a commodity to the user. **The experience is the product.**

### 6.1 Principles
1. **Never make me babysit.** Zero-decision defaults; the app resolves problems and reports afterward.
2. **Progress must feel alive.** Real speed, real ETA, real per-connection detail — the engine already emits all of it.
3. **Usable before it's finished.** Sequential download + preview means value at 5%, not 100%.
4. **Honest failure.** `DownloadError` cases are specific — surface them plainly ("server doesn't support resuming") with a real next action, never "Something went wrong."

### 6.2 The three flows that must be flawless

**Add.** Share Sheet → sheet appears with resolved **name, size, type, save location** (engine's `resolveMetadata` already does this) → one tap. Adding a download should take under three seconds and one decision.

**Watch it work.** The list is the app. Per-row: name, progress, live speed, ETA. Tapping opens detail with the segment/connection view — a genuinely beautiful, differentiated visualization of parallel transfer that no competitor can show. **Live Activity means you watch progress without opening the app.**

**Consume.** The instant a file is playable, a **Play** button appears — not after completion. Video/audio/PDF/image/archive preview in-app.

### 6.3 Signature moments (what earns the word-of-mouth)
- Side-by-side with Safari on the same file, visibly faster
- Locking the phone and watching the Dynamic Island tick up
- **Pausing a 4 GB download from the Dynamic Island without opening the app** (§6.5)
- Hitting play at 8% and it just works
- Airplane-mode toggle → "Resumed" with no lost bytes
- Glancing at the Lock Screen and simply *knowing* it's still working

### 6.4 Continuity (V1.2)
Start on Mac → arrives on phone. This is the reason a desktop user installs the app, and no competitor can copy it because they have no desktop.

### 6.5 Glanceable surfaces — Live Activity, Lock Screen, Dynamic Island

**This is where a download manager earns its reputation.** The whole promise of §4.1 is "you don't have to babysit it" — which is only *believable* if the user can see it working without unlocking the phone. These are not polish; they are the proof of the thesis.

Three distinct technologies with three different constraint sets. Conflating them is the classic mistake:

| Surface | Technology | Update model | Job |
|---|---|---|---|
| **Live Activity** (Lock Screen + banner) | ActivityKit | Push/app-driven, **best-effort** | The *live* per-download progress |
| **Dynamic Island** | Same Live Activity, different presentations | Same | Live progress while using other apps |
| **Lock Screen widget** | WidgetKit `.accessory*` | **Timeline, budgeted (tens/day)** | At-a-glance *aggregate* state |
| **Home Screen / StandBy widget** | WidgetKit | Timeline, budgeted | Queue summary, launch point |

#### Live Activity + Dynamic Island (the hero)

Presentations required — all four must be designed, not just the pretty one:

| Presentation | Content |
|---|---|
| **Lock Screen / banner** | Filename, progress bar, %, speed, ETA, **Pause + Cancel buttons** |
| **Dynamic Island — compact** | Leading: app glyph / kind icon · Trailing: **% or a circular progress ring** |
| **Dynamic Island — minimal** | Progress ring only (when sharing the Island with another activity) |
| **Dynamic Island — expanded** (long-press) | Filename, progress, speed, ETA, **Pause/Resume + Cancel** |

**Interactivity is the differentiator.** iOS 17+ allows `Button`/`Toggle` backed by **App Intents** inside Live Activities and widgets. **Pausing a 4 GB download from the Dynamic Island without ever opening the app** is the single most demo-able thing in this product. Requires an `AppIntent` layer over the manager's `pause`/`resume`/`remove` — trivial work, outsized payoff.

**Multi-download behavior:** one Live Activity per *active* download is noisy. **Rule:** a single aggregate activity ("3 downloads · 62%") when >1 is active, auto-collapsing to a per-file activity when only one remains. iOS also caps concurrent activities — do not fight it.

#### The hard constraint (read this before promising anything)

**A Live Activity cannot smoothly animate progress while the app is suspended.** ActivityKit updates come from (a) the app while it has execution time, or (b) **ActivityKit push notifications** from a server. During a background `URLSession` transfer the app is *not* continuously running — the system runs the transfer out-of-process and wakes us on events, not on every byte.

**Consequences we design for, rather than discover in beta:**
- Progress will be **coarse and occasionally stale** while backgrounded — steps, not a smooth crawl
- Use `ActivityContent(state:staleDate:)` so a stale activity **visibly degrades honestly** ("Downloading…" without a lying percentage) instead of freezing at a wrong number
- Prefer **byte-count + "updated 2m ago"** over a precise-looking ETA that is actually stale
- Background `URLSession` delegate callbacks are the primary update trigger; opportunistically refresh on every wake
- Live Activities are **system-limited to roughly 8 hours of updates (~12 hours visible)**. A multi-hour download can outlive its activity — the app must handle activity expiry gracefully and fall back to a completion notification

> **Explicitly rejected:** running a push server purely to animate progress bars. Disproportionate cost, privacy surface, and a hard dependency for a cosmetic gain. Revisit only if V1.2 continuity already gives us a server relationship.

#### Lock Screen accessory widgets

`.accessoryCircular` (progress ring + count), `.accessoryRectangular` (top download: name, bar, ETA), `.accessoryInline` (one line beside the clock).

**These are timeline widgets, not live.** WidgetKit grants a *budget* of refreshes per day — **do not attempt per-second progress here** and do not let a user compare the widget to the Live Activity and see disagreement. Design them for **aggregate, slow-moving truth** ("4 active · 1.2 GB left"), refreshed via `WidgetCenter.reloadTimelines` whenever the app has execution time. The Live Activity is the live surface; the widget is the ambient one.

#### Acceptance criteria
- Live Activity appears within **1s** of a download starting, on Lock Screen *and* Dynamic Island
- Pause/resume from Dynamic Island works **without launching the app**, and the queue reflects it immediately
- Backgrounded progress never displays a *confidently wrong* number — stale states are visibly stale
- Non-Dynamic-Island devices (and iPads) degrade cleanly to Lock Screen + banner only
- Widgets never contradict the Live Activity by more than one refresh interval

---

## 7. Technical requirements

Builds directly on Stage 1a (complete):

| Layer | Status |
|---|---|
| `GoelContracts` (platform-free, zero deps) | ✅ shipped |
| `GoelCore` (engine) | ✅ builds standalone without torrent/portal |
| `GoelFacade` (sync/callback boundary) | ✅ shipped — *note: the SwiftUI app should use the **async** manager directly; the facade exists for JNI/Android* |
| `GoelTorrent` / `GoelRemoteServer` | ✅ excludable — omitted from the iOS product |

**Stage 1b prerequisites (nothing below can start until these land):**
1. **libcurl + libssh2 as iOS static xcframeworks** — the hard gate; the engine cannot compile for iOS without them
2. `.iOS(.v17)` platform in `Package.swift`
3. **iOS port adapters** — power (UIKit), FileStore (container), Archive (`Compression`; `ditto` does not exist on iOS). *Only desktop implementations exist today.*
4. **`BackgroundTransfer` iOS conformer** (§4.1) — the real work
5. Xcode/`xcodebuild` destination in CI — plain `swift build` cannot target the iOS SDK

**UI:** SwiftUI, iOS 17+, observing the manager's `AsyncStream` snapshots (the pattern `AppViewModel` already uses on macOS).

**Additional targets required for §6.5** (each is a separate extension, with its own memory limit and its own build of the engine's contract types):
- **Widget extension** — hosts both the WidgetKit widgets *and* the Live Activity views
- **ActivityKit** — `NSSupportsLiveActivities` in Info.plist; a `ActivityAttributes` type modelling one download *and* the aggregate case
- **App Intents** — `PauseDownloadIntent` / `ResumeDownloadIntent` / `CancelDownloadIntent`, shared by the Live Activity buttons, Shortcuts and Siri. **These must reach the engine from an extension process**, so queue state has to be readable/mutable outside the app — an **App Group container** for the SQLite store, or a lightweight command file the app drains on next wake. *This is a real architectural requirement, not a UI detail — it needs designing at M0, not bolted on at M3.*
- **Share Sheet extension** (add-from-anywhere) and **File Provider extension** (§4.2) — also separate targets

`GoelContracts` being platform-free and dependency-free is what makes it cheap to link into every one of these extensions.

---

## 8. Risks & compliance — read before committing

### 8.1 BitTorrent is excluded, and that is a product decision
Apple has consistently rejected BitTorrent clients under App Review Guideline 1.4.3 / copyright provisions. Shipping torrent support risks rejection of *the entire app*. **We exclude it from the App Store build** (the W3 modularization already makes `GoelTorrent` droppable). Revisit only via a separate distribution channel, never as a launch dependency.

### 8.2 App Review risk on a general-purpose downloader
Media-downloading apps attract scrutiny (YouTube-style extraction is a known rejection trigger). **Mitigations:** no site-specific extractors, no bundled `yt-dlp`, no piracy-adjacent affordances in marketing or screenshots. Position explicitly as a **file transfer manager** (SFTP/FTP/HTTP), not a "video downloader."

### 8.3 Other risks
| Risk | Severity | Mitigation |
|---|---|---|
| Background handoff corrupts files | **Critical** | Checksum every handoff in testing; §4.1 acceptance test gates release |
| Servers without range support | High | Detect at add time (`resolveMetadata`), warn honestly |
| iOS storage pressure / jetsam on large files | High | Stream to disk (never buffer whole files); handle low-space (`DownloadError.diskFull`) |
| xcframework build complexity (OpenSSL for libcurl/libssh2) | Medium | Budget real time; this is the schedule's long pole |
| Battery drain from multi-connection | Medium | Throttle on Low Power Mode via the power port |
| **Live Activity shows stale/wrong progress while suspended** | **High** | `staleDate` + honest degraded states (§6.5); never render a confident wrong number |
| **App Intents can't reach engine state from an extension** | **High** | App Group container decided at **M0**, not M3 — retrofitting shared state is expensive |
| Live Activity outlives its ~8h system budget on long downloads | Medium | Graceful expiry → completion notification fallback |

---

## 9. Success metrics

**Primary (the thesis):**
- **Download completion rate ≥ 97%** for transfers that get backgrounded — *the number that proves we solved §4.1*
- **Median throughput ≥ 2× Safari** on the same multi-mirror file

**Secondary:** D30 retention ≥ 25% · ≥ 40% of sessions use play-while-downloading · crash-free ≥ 99.5% · App Store rating ≥ 4.6 · ≥ 15% of desktop users install the phone app (V1.2 moat check)

**Counter-metric:** support contacts mentioning "stopped"/"stuck"/"lost progress" — if this rises, §4.1 is not solved regardless of what the completion number says.

---

## 10. Milestones

| # | Milestone | Exit criteria |
|---|---|---|
| **M0** | iOS engine compiles | xcframeworks built; `.iOS(.v17)`; port adapters in; GoelCore+GoelContracts compile for device. **Plus: App Group / shared-state decision made (§7)** — extensions must be able to reach the queue |
| **M1** | **Background transfer proven** | §4.1 acceptance test passes repeatedly. **Hard gate — do not build UI before this.** Includes the §6.5 spike measuring how coarse backgrounded progress actually is |
| **M2** | Usable alpha | Add → download → play → save. **Live Activity + Dynamic Island landing here, not at M3** — it is the proof of M1, and the earliest honest demo of the product |
| **M3** | Feature-complete V1 | Lock Screen + Home Screen + StandBy widgets, App Intents everywhere, File Provider, HLS, notifications |
| **M4** | Public beta | 100+ TestFlight users; completion-rate metric instrumented |
| **M5** | App Store launch | Review passed; crash-free ≥ 99.5% |

**M1 is deliberately placed before any UI work.** Building the interface first and discovering background transfer is unsolvable would waste the entire investment.

---

## 11. Open questions

1. **Does the segmented→background handoff hold up under real-world server behavior** (ETag churn, CDN mismatch across nodes)? Needs a spike before M1 is scoped.
2. **HLS in the background** — segment-by-segment fetch doesn't map onto a single background `URLSession` task. Possibly foreground-only in V1; needs a decision.
3. **Pricing** — paid up front, or free with a one-time unlock for SFTP/continuity?
4. **Do we need the File Provider extension at launch,** or is Save-to/Share-out enough for V1?
5. **iPad at launch** or fast-follow?
6. **How coarse is backgrounded Live Activity progress in practice?** Needs a measurement spike alongside M1 — it determines whether we show a percentage at all while suspended, or switch to a byte-count + "updated Nm ago" model.
7. **App Group vs. command-file for extension→engine control** (§7). Affects the persistence layer, so it must be settled at M0.

---

## Appendix — engine features intentionally dropped on iOS

Aggregation/multi-adapter bonding · post-download scripts · antivirus scan · watch folders · remote-control server · arbitrary save paths · `ditto` archive extraction (replaced by `Compression`) · BitTorrent (§8.1).
