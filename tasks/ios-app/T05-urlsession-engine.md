# T05 — `URLSessionTransferEngine` — real segmented HTTP

**Goal:** actually download files, fast, in parallel, with correct resume. This is the
product. Give it the time it deserves.

## First: the test harness

**`Scripts/ios/range-server.py`** — a stdlib-only HTTP server that is honest about ranges,
because Python's `SimpleHTTPRequestHandler` does **not** support `Range` and will silently
hand you the whole file, making a broken segmenter look like it works.

Requirements:
- Serves a directory on `:8099`.
- `HEAD` → `Content-Length`, `Accept-Ranges: bytes`, `ETag`, `Last-Modified`, `Content-Type`.
- `GET` with `Range: bytes=a-b` → `206 Partial Content`, correct `Content-Range`, exact slice.
- `GET` with `If-Range:` → honors it; `412` when the validator does not match.
- Handles concurrent requests (`ThreadingHTTPServer`).
- `--no-ranges` flag: omit `Accept-Ranges` and ignore `Range`. You need this to test the
  non-resumable path.
- `--throttle BYTES_PER_SEC` so speeds and ETAs are observable rather than instant.

Generate fixtures once: `mkfile -n 200m` (or `dd`) into `Scripts/ios/fixtures/`.
The simulator reaches the host directly — `http://localhost:8099/test-200mb.bin` works.

Verify the server **with `curl` before trusting it**:
```bash
curl -sI http://localhost:8099/test-200mb.bin | grep -i accept-ranges
curl -sr 0-99 http://localhost:8099/test-200mb.bin -o /dev/null -w '%{http_code}\n'   # 206
```

## Build

**`Goel/Engine/URLSessionTransferEngine.swift`** — an `actor`.

**Probe** (`probe(_:)`): `HEAD`; if the server rejects HEAD, fall back to
`GET` with `Range: bytes=0-0`. Extract length, `Accept-Ranges`, `ETag`/`Last-Modified`,
MIME, and a filename from `Content-Disposition` → last path component → `"download"`.

**Segmented download:**
1. If `supportsResume` and `totalBytes >= 8 MB` → split into **6 segments** (match the
   mockup; make it a constant, not a literal). Otherwise a single stream.
2. One `URLSessionDataTask` per segment with `Range: bytes=<start>-<end>` and
   `If-Range: <etag>`.
3. Each segment writes into **one preallocated sparse file** at its own offset using a
   `FileHandle` — `seek(toOffset:)` + `write`. Do **not** download to six temp files and
   concatenate; that doubles disk and breaks T10's play-while-downloading.
4. Serialize file writes through the actor, or use one `FileHandle` per segment on
   non-overlapping ranges. Never share a `FileHandle` across concurrent writers.
5. Emit `.progress` at **most 10 Hz**, aggregated across segments. A per-chunk event
   will flood the main actor and drop frames.
6. Persist a **cursor per segment** after each write so a kill mid-transfer resumes
   correctly rather than restarting.

**Sequential mode** (`isSequential == true`, T10 needs it): segments still run in
parallel, but a segment may not start ahead of a gap — allocate strictly in order so bytes
`0…n` are always contiguous and the file is playable while incomplete.

**Failure handling — no silent failures:**
- `416 Range Not Satisfiable` or an `If-Range` mismatch → the remote file changed. Restart
  from zero, emit `.statusChanged`, and surface it. Do not silently produce a corrupt file.
- A segment that fails retries **3 times with exponential backoff**; then its range is
  handed to another segment; only if the whole set fails does the download fail.
- Server does not support ranges → single stream, `supportsResume = false`, and the UI says
  so up front (PRD §4.1: *"we say so honestly up front rather than failing at 99%"*).
- Every `catch` either recovers or emits `.failed`. **No empty catch blocks.**

**Verification:** on completion, if the URL had a sidecar `.sha256`, verify and set
`checksumVerified`. Absent one, leave it `false` — do not claim verification you did not do.

## Exit criteria

- With `range-server.py --throttle 20000000` running, the app downloads
  `test-200mb.bin` end to end. Compare `shasum` of the simulator's container copy against
  the source. **They must match.** This is the task's real gate.
- Kill the app at ~40%, relaunch, resume → completes, checksum still matches.
- `--no-ranges` mode → single stream, completes, `supportsResume == false`.
- Unit tests: range-header construction, segment split arithmetic (including a remainder
  that does not divide evenly), 416 handling, backoff.
- `git commit -m "ios(T05): segmented URLSession transfer engine"`

## Notes

- Segment arithmetic off-by-one is the classic bug here. `bytes=0-99` is **100** bytes,
  inclusive on both ends. Unit-test the split with a size that is not a multiple of 6.
- Measure before optimizing chunk size. Correctness and a matching checksum first.
- Do not start on T06 until the checksum matches. A background handoff built on a
  subtly-wrong segmenter is unfixable later.
