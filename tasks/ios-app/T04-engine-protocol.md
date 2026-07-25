# T04 — `TransferEngine` protocol + preview implementation

**Goal:** the seam that makes tonight possible and keeps `GoelCore` viable later.
Read `START.md § The engine decision` before starting.

## Build

**`Goel/Engine/TransferEngine.swift`**

```
protocol TransferEngine: Actor {
    func start(_ download: Download) async throws
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func cancel(_ id: UUID, deleteData: Bool) async
    func probe(_ url: URL) async throws -> ProbeResult
    var events: AsyncStream<TransferEvent> { get }
}

struct ProbeResult: Sendable {
    var filename: String
    var totalBytes: Int64?
    var supportsResume: Bool          // Accept-Ranges: bytes
    var mimeType: String?
    var isStreamable: Bool            // video/* and seekable
}

enum TransferEvent: Sendable {
    case progress(id: UUID, received: Int64, total: Int64?, speed: Double, segments: [Segment])
    case statusChanged(id: UUID, status: Download.Status)
    case completed(id: UUID, fileURL: URL)
    case failed(id: UUID, message: String)
}
```

Design constraints, all deliberate:
- **`events` is one stream for all downloads**, not one per download. Views subscribe once.
- Every method is `async` and non-throwing except `start`/`probe`. A pause that silently
  no-ops is a bug; a pause that throws is noise.
- `TransferEvent` is `Sendable` and carries only value types. Nothing here may reference
  a `URLSessionTask`.

**`Goel/Engine/PreviewTransferEngine.swift`**
- An `actor` implementing the protocol with a deterministic simulation: seeded, fixed
  timestep, no `Date()` and no `Task.sleep` jitter in the values it emits.
- Reproduces exactly the state shown in `visual.html`, because T07/T08 screenshots are
  compared against those frames:

| Filename | Size | State |
|---|---|---|
| `ubuntu-24.04.1-desktop-amd64.iso` | 5.73 GB | downloading, **63%**, 48.2 MB/s, 6 segments at 100/78/64/57/41/22% |
| `nas-backup-2026-07-14.tar.zst` | 12.6 GB | downloading, 31%, 12.4 MB/s, sftp |
| `keynote-2026-4k-hdr.mp4` | 2.1 GB | downloading, 23%, sequential, streamable |
| `dataset-imagenet-subset.tar` | 18 GB | `waitingForWiFi`, 8% |
| `Blender-4.2-macOS-arm64.dmg` | 412.3 MB | completed, checksum verified, 2 min ago |

- Add `PreviewTransferEngine.static` — frozen, no ticking — for SwiftUI previews and
  screenshot determinism, and `.live` which advances so you can watch animation.

**Wire it up:** `RootView` takes the engine via environment. A launch argument
`-uiTestingPreviewEngine` selects `PreviewTransferEngine.static`. That flag is how every
later screenshot task gets identical, comparable output:

```bash
xcrun simctl launch "$SIM" dev.goel.ios -uiTestingPreviewEngine
```

## Exit criteria

- Build green; both engines conform without `@unchecked Sendable` anywhere.
- A unit test drives `PreviewTransferEngine.static` and asserts the ubuntu row is exactly
  `0.63` and reports 6 segments with the percentages above.
- `git commit -m "ios(T04): TransferEngine seam and deterministic preview engine"`

## Notes

- This protocol is the contract `GoelCore` will implement later via `GoelFacade`. Keep it
  free of `URLSession` types so that stays true. If you find yourself wanting to expose a
  `URLSessionTask`, you are leaking the implementation through the seam.
- Do not import `GoelCore`. It does not build for iOS.
