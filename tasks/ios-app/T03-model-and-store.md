# T03 — Domain model + App Group store

**Goal:** the state every other task reads, persisted where the widget extension can see it.

## Build

**`Goel/Model/Download.swift`**

```
struct Download: Identifiable, Codable, Sendable, Equatable
  id: UUID
  url: URL
  filename: String
  saveDirectory: String
  kind: Kind                     // .http .https .ftp .sftp .hls   (no .torrent — PRD §8.1)
  status: Status
  totalBytes: Int64?             // nil = server did not report a length
  receivedBytes: Int64
  segments: [Segment]
  speedSamples: [Double]         // ring buffer, last 60, for the sparkline
  addedAt: Date
  completedAt: Date?
  checksumVerified: Bool
  isSequential: Bool             // T10 — play while downloading
  supportsResume: Bool           // server advertised Accept-Ranges
  errorMessage: String?

enum Status: Codable, Sendable   // queued, probing, downloading, paused,
                                 // waitingForWiFi, verifying, completed, failed
struct Segment: Codable, Sendable, Identifiable
  id: Int, range: ClosedRange<Int64>, receivedBytes: Int64, isActive: Bool
```

Computed, all `NaN`-safe:
- `fractionComplete: Double` — `0` when `totalBytes` is nil or 0.
- `currentSpeed: Double` — mean of the last 3 samples.
- `eta: TimeInterval?` — `nil` when speed is 0 or size unknown. **Never `inf`.**

Encoding: **pin `JSONEncoder.dateEncodingStrategy = .secondsSince1970`.** Foundation's
default is seconds since 2001, a 31-year silent offset. The desktop facade already made
this exact choice (`GoelFacade.makeEncoder`); match it.

**`Goel/Model/DownloadStore.swift`**
- `@MainActor @Observable final class DownloadStore`
- `private(set) var downloads: [Download]`, indexed by `id` in a dictionary for O(1) update
  — the queue updates several times a second and a linear scan per tick will show.
- `add / update / remove / pause / resume / clearCompleted`
- Persists to the App Group container as JSON, **debounced ~500ms** — do not write on every
  progress tick.
- Loads on init. A corrupt or absent file yields an empty store plus an `os_log` warning,
  never a crash.

**`Shared/SharedSnapshot.swift`** — the narrow slice widgets read. Keep it small; widget
memory limits are tight.

```
struct SharedSnapshot: Codable, Sendable
  activeCount: Int
  totalRemainingBytes: Int64
  aggregateFraction: Double
  updatedAt: Date
  top: [Item]      // max 3 — id, filename, fraction, speed, kindToken
```

- `SharedSnapshot.write(_:)` / `.read()` against
  `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.goel.ios")`.
- If that returns `nil`, fall back to `.applicationSupportDirectory`, log a warning, continue.
- `DownloadStore` writes a snapshot whenever it persists, then calls
  `WidgetCenter.shared.reloadAllTimelines()` — **rate-limit that to at most once every
  15 seconds.** WidgetKit budgets reloads; hammering it gets you throttled and the widgets
  go stale, which is worse than updating slowly.

## Exit criteria

- `GoelTests` covers, and passes:
  - Formatter table from T02 — `5.73 GB`, `48.2 MB/s`, `44s left`, `63%`.
  - `fractionComplete` with `totalBytes == nil` → `0`, not `NaN`.
  - `eta` with speed `0` → `nil`, not `inf`.
  - Round-trip `Download` → JSON → `Download` is `==`.
  - Date encodes as Unix seconds (assert a known value, e.g. `1700000000`).
  - Store survives: write, re-init from disk, same contents.
- `xcodebuild ... test` green.
- `git commit -m "ios(T03): domain model and app-group persisted store"`

## Notes

- No torrent case anywhere. `docs/PRD-iOS.md` §8.1 excludes BitTorrent as a product
  decision under App Review Guideline 1.4.3. Do not add it "just in case."
- `speedSamples` is a bounded ring buffer. An unbounded array on a multi-hour download is
  a memory leak that will not show up until it matters.
