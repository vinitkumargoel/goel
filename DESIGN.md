# DESIGN (FINAL) — Mid-flight connection growth + network aggregation for single-connection downloads

Branch: `feat/single-conn-aggregation`. Scope: W1 per-adapter governors, W2 mid-flight
single→segmented upgrade, W3 bound-path live progress + reason surfacing.
Line anchors refer to the current working tree (commit 2aa633f).

**Status: FINAL, amended after post-implementation code review.** The adversarial
critique has been folded into the body: every fix is stated inline where the issue
lived, marked `[F#]` with the finding number. Rejected critique remedies are listed
at the end, followed by the binding edit plan. An implementer needs only this file
plus the named source files; every design decision is already made.

**Amendment pass (post-review).** W1–W3 shipped, then a code review of the merged
result found five defects in `SegmentedTransfer.swift`; all five are fixed in the
working tree, and a sixth item is a behavior delta that was shipped without being
written down. Every place this document described the superseded behavior has been
rewritten in-body and marked `[R#]` with the review-fix number, and each carries a
decision-log entry (25–30). Where an `[F#]` decision was overturned, the original
decision-log entry is left standing and annotated as superseded rather than edited
away — the reasoning that produced the defect is part of the record. See
`## Notes Fix` at the end for the fix pass itself and the current verification state.

Verified ground truth used throughout:

- `gcb_http_write_thunk` (curl_bridge.c:211-241) **drains** every non-success body
  (`http_status != 206` for ranged mode, `!= 200` for unranged) without calling the
  Swift write callback, and sets `reject_body` **before the first body byte** on a
  missing/mismatched `Content-Range` when `expected_total > 0`. Therefore: bytes that
  reach `BoundHTTPClient`'s `onBytes` are exactly the bytes written to disk for an
  accepted response, and `Response.bytesWritten == Σ onBytes` always. This is the
  invariant W3's ledger change rests on, and it already holds — W3 itself needs no C
  changes. (W2 *does* make two small C additions — validator capture and ranged-200
  early abort, both specified below — neither touches this invariant: the new
  ranged-200 branch returns 0 **before** `write_cb` is invoked.)
- `gcb_is_aborted` == `CURLE_ABORTED_BY_CALLBACK` only (curl_bridge.c:104), which is
  produced by the **progress** thunk returning 1. [R5] This does NOT mean the W2
  signal-abort must ride the progress thunk, and the original wording here (and the
  shipped comment above `shouldAbort` in `runSingleBound`) wrongly said it did.
  `Response.aborted` is `gcb_is_aborted(raw.code) != 0 || ctx.aborted`
  (BoundHTTPClient.swift:189), and `ctx.aborted` re-reads the `shouldAbort` closure —
  so the trip is observed no matter which thunk stopped curl. In practice a mid-body
  trip stops curl through the **write** thunk (BoundHTTPClient.swift:212, `return 0`
  → `CURLE_WRITE_ERROR`), because that is the callback curl invokes per body chunk;
  the progress thunk (:227) covers the pre-body/connect phase. The design was always
  correct — folding `shouldAbort` into `aborted` is exactly what makes both channels
  equivalent — only the stated invariant was wrong. Corollary used by [F2] still
  holds unchanged: the ranged-200 early abort is set purely inside C and never
  touches `ctx.aborted`, so it does NOT set `Response.aborted` and cannot be misread
  as a pause.
- `GoelLogger.notice` takes a `StaticString` message + `GoelLogField...`; dynamic text
  must go in typed fields (`.detail(...)`, `.host(...)`, `.count(_:label:)`,
  `.bytes(_:label:)`, `.flag(_:label:)`, `.url(...)`) — GoelLog.swift:361, 96-200.
- `streamSingle` currently **discards** the accepted 200's `HTTPURLResponse`
  (`guard let (_, bytes, streamer) = result`, SegmentedTransfer.swift:666). W2 [F1]
  starts binding it.
- `gcb_http_range` follows redirects manually (hop loop, curl_bridge.c:430+,
  `FOLLOWLOCATION` off), so within one hop a `200` is always a **final** response,
  never a redirect interstitial — which is what makes the [F2] write-thunk abort safe.

---

## W1 — Per-adapter connection governors

### New type: `AdapterGovernors` (ConnectionGovernor.swift, appended after line 96)

```swift
/// Per-adapter concurrency limiters for multi-path segmented downloads.
///
/// A 429 on one adapter's source IP says nothing about the other NICs — per-IP
/// limits are per source address — so throttling the download-wide governor for
/// it would starve healthy paths. Each adapter gets its own monotonic-decreasing
/// ``ConnectionGovernor``; the download-wide governor keeps the aggregate ceiling.
///
/// The key set is fixed at init (the plan's bound adapters never grow mid-run),
/// so this is an immutable dictionary of actors — cancellation safety is
/// inherited from ``ConnectionGovernor/acquire()`` verbatim instead of being
/// re-implemented. An unknown key is a no-op rather than a trap: the pump must
/// never deadlock on bookkeeping.
final class AdapterGovernors: Sendable {
    private let governors: [String: ConnectionGovernor]

    init(adapters: [BoundAdapter], limit: Int) {
        var map: [String: ConnectionGovernor] = [:]
        for a in adapters where map[a.bsdName] == nil {
            map[a.bsdName] = ConnectionGovernor(limit: limit)
        }
        self.governors = map
    }

    func acquire(_ bsdName: String) async throws { try await governors[bsdName]?.acquire() }
    func release(_ bsdName: String) async { await governors[bsdName]?.release() }
    func throttleDown(_ bsdName: String) async { await governors[bsdName]?.throttleDown() }
}
```

Decision: a `Sendable` class wrapping `ConnectionGovernor` actors, not a new actor —
reuses the proven waiter/cancel machinery (acquire re-check under actor isolation,
cancel handler dequeues parked waiters) instead of duplicating it; the map is
immutable so no isolation is needed at this layer.

### Changes in `SegmentedTransfer.runSegmented` (currently :140)

After `let adapterPool` (:165-166) add:

```swift
// One governor per adapter, each starting wide open (limit = ranges.count) so
// behavior is byte-identical to today until the first 429 arrives on some path.
let adapterGovernors: AdapterGovernors? = plan.boundAdapters.isEmpty
    ? nil : AdapterGovernors(adapters: plan.boundAdapters, limit: ranges.count)
```

In the task group (:182), `if let adapterPool` becomes `if let adapterPool, let
adapterGovernors` and passes `adapterGovernors` down.

### Changes in `downloadSegmentBound` (currently :351-503)

1. Signature gains `adapterGovernors: AdapterGovernors,` after `governor:` (and
   `upgraded: Bool` for [F2], see W2).
2. After `try await governor.acquire()` (:375) — global THEN adapter, and the global
   slot must be returned if the adapter acquire is cancelled while parked:

```swift
do { try await adapterGovernors.acquire(adapter.bsdName) }
catch { await governor.release(); throw error }
```

3. Every `await governor.release()` inside the loop (:402, :411, :426, :440, :445,
   :463, :475 — plus the new [F2] `rangeIgnored` branch) becomes the reverse-order
   pair:

```swift
await adapterGovernors.release(adapter.bsdName)
await governor.release()
```

   (`adapter` is bound per-iteration at :370, so retries that were reassigned a
   different adapter release the governor they actually acquired.)
4. `.retry` case (:439): `await governor.throttleDown()` → `await
   adapterGovernors.throttleDown(adapter.bsdName)`. The global governor is never
   throttled on this path anymore — the aggregate ceiling stays `ranges.count`.

`downloadSegment` (URLSession single-path route, :212) is untouched by W1 (it gains
only the [F2] `upgraded` flap-retry branch from W2).

### Contract change, owned explicitly [F9]

Removing the global `throttleDown` in multi-path means total concurrent connections
to a 429ing host no longer shrink — only the receiving adapter's path does. This is
correct under the per-source-IP premise this feature is built on, and it is a
**deliberate trade-off**: a server that rate-limits per credential/token (the
`Authorization` header is identical on every path) will now see sustained fan-out
pressure from the healthy NICs where today the whole download backs off. Accepted:
per-credential limiters answer every path with 429s, so each adapter governor still
converges down individually; convergence is merely slower (one 429 per adapter
instead of one shared). Recorded in the decision log so a future 429 storm is not
misdiagnosed as a W1 bug.

### Isolation / cancellation / deadlock analysis

- `adapterGovernors.acquire` is the only new **throwing** await; its only throw is
  `CancellationError`, and the `catch` above rebalances the global slot before
  rethrowing — every acquire is still balanced by exactly one release per exit path.
- `release`/`throttleDown` are non-throwing actor hops; they complete even on a
  cancelled task (actor calls do not implicitly check cancellation), same as the
  existing `governor.release()` on unwind paths.
- No deadlock: global limit is `ranges.count` == the number of claimants, and W1
  removes the only `throttleDown` on the global governor in multi-path, so a global
  acquire never parks; holding it while parked on an adapter governor blocks no one.
  Lock order (global → adapter) is identical for all claimants regardless.

---

## W2 — Mid-flight upgrade from single stream to segmented

### Trigger gate (pure, static, in SegmentedTransfer)

```swift
/// Below this size a mid-flight re-segmentation costs more than it saves.
static let upgradeMinBytes: Int64 = 8 * 1024 * 1024
/// Mirrors ``AggregationPolicy/multiPathSegmentCount``'s hard cap; the engine
/// clamps further by profile/budget when granting.
static let upgradeMaxConnections = 32

/// Without a validator the streamed prefix cannot be proven identical to ranged
/// bytes fetched later, so the upgrade must never fire.
static func shouldAttemptUpgrade(totalBytes: Int64?, acceptsRanges: Bool,
                                 etag: String?, lastModified: String?) -> Bool {
    guard let total = totalBytes, total >= upgradeMinBytes, !acceptsRanges else { return false }
    return etag != nil || lastModified != nil
}
```

### Entity identity — the full validator triangle [F1]

The upgrade mixes bytes from two responses (the streamed prefix and the ranged tail)
under one file. Both must be tied to the SAME entity, which requires **two** edges,
each using the `validatorsAllowResume` rule (etag pair match, else last-modified pair
match, else refuse):

1. **probe edge** — ranged midpoint 206's validators == `plan.etag`/`plan.lastModified`
   (checked inside `probeMidpointRange`; a mismatch means the ranged tail would come
   from a different entity than the probe described → no trip).
2. **stream edge** — the accepted streaming response's validators ==
   `plan.etag`/`plan.lastModified` (a mid-deploy CDN can serve v2 from one edge while
   another still 206s v1; without this edge the final file could be a v2 prefix + v1
   tail passing every byte-count net).

Stream-edge enforcement per path:

- **URLSession path** (`streamSingle`): the accepted response is already in `result`
  (:666) — bind it (`guard let (http, bytes, streamer) = result`), and thread the
  upgrade signal into `pumpBody` ONLY when the stream edge holds:

```swift
// The 200 actually streaming must be the entity the probe described: the
// on-disk prefix and any ranged tail fetched after an upgrade must come from
// one representation. On mismatch the stream is left to complete untouched
// (today's behavior); only the upgrade is disabled.
let entityTied = Self.validatorsAllowResume(
    cursorETag: plan.etag, cursorLastModified: plan.lastModified,
    probeETag: http.value(forHTTPHeaderField: "ETag"),
    probeLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
if !entityTied {
    GoelLog.engineHTTP.debug("Mid-flight upgrade disabled: stream entity differs from probe",
                             .url(plan.url))
}
let pumpUpgrade = entityTied ? upgrade : nil   // threaded to pumpBody
```

  A mismatched stream therefore NEVER aborts — the download completes single-stream
  exactly as today (the prober keeps probing harmlessly, bounded at 5 attempts, and
  its trips are simply never read).

- **Bound path** (`runSingleBound`): validators are unobservable mid-flight over
  curl, so the C header thunk is extended to capture `ETag` / `Last-Modified` into
  `GCBHTTPResult` (two `strncasecmp` branches — see "CurlBridge changes" below), and
  the stream edge is checked in the aborted branch AFTER the trip already stopped
  curl. Consequence: on the bound path a trip aborts first and validates second.

  [R1] **A failed stream edge does not fail the download — it discards the prefix.**
  The original design threw `DownloadError.remoteFileChanged` whenever the stream
  edge failed with `written > 0`. That was wrong, for a reason the design had the
  facts for and did not connect: the two edges do not see the same representation.
  The probe rides URLSession, which sends the default `Accept-Encoding: gzip,
  deflate`; every bound request rides curl through `gcb_http_headers`, which appends
  `Accept-Encoding: identity` unconditionally (curl_bridge.c:413, pre-existing, not
  a W2 addition). Origins that vary the validator by content-coding legitimately
  answer with different ETags for the same entity — Apache `mod_deflate` appends
  `-gzip`, nginx and Cloudflare weaken or rewrite it. So on those origins a stream-edge
  mismatch routinely means "same file, different representation", not "the remote
  changed". The old code turned that into a permanent, self-repeating failure of a
  download that had been completing fine before the branch existed: the retry
  re-probes to the same unranged verdict, trips again, and throws again. It also
  fired when the stream had already delivered the complete body (`written == total`),
  where there is nothing left to mix.

  The rule is now:

```swift
let keepsPrefix = written == 0 || written == upgrade.total
    || Self.validatorsAllowResume(
        cursorETag: plan.etag, cursorLastModified: plan.lastModified,
        probeETag: response.etag, probeLastModified: response.lastModified)
```

  On `keepsPrefix == false` the transfer logs a notice and calls
  `upgradeToSegmented(total: upgrade.total, written: 0)` — the unprovable prefix is
  discarded and `[0, total-1]` is refetched over ranges. That is *correct* (every
  byte in the final file then comes from the one ranged entity, so nothing is
  spliced) and still faster than the single stream it replaces (it is the fan-out
  the upgrade exists to buy). Cost: the streamed prefix bytes are paid for twice on
  those origins. `written == 0` and `written == upgrade.total` short-circuit ahead of
  the validator call — an empty prefix has nothing to mismatch, and a complete one
  makes `upgradeToSegmented` return the finished outcome without segmenting at all.

  Second defect disarmed for free: the C capture buffers truncate long validators
  (`char etag[256]` — S3 multipart and long composite ETags overflow it), which
  guarantees an equality failure. Under the old rule that was a permanent download
  failure; under this one it degrades to a prefix-discarding refetch.

Decision: restricting the bound-path upgrade *unconditionally* to `W == 0` was
rejected — the prober fires at ≥ 10 s, by which time W > 0 on any live link, so that
restriction would have gutted the bound upgrade (the path this feature exists for).
[R1] narrows it to exactly the case that needs it: the upgrade proceeds with the
prefix when it is provable, and with `W == 0` when it is not.

### TransferPlan additions (SegmentedTransfer.swift :1172-1200)

```swift
/// Mid-flight range re-probe cadence. Exists as data so tests can compress the
/// schedule; production always runs the defaults.
struct UpgradeProbing: Sendable {
    var initialDelay: TimeInterval = 10
    var interval: TimeInterval = 30
    var maxAttempts: Int = 5
}
// on TransferPlan:
var upgradeProbing = UpgradeProbing()
/// Engine-supplied channel to charge additional connections against the
/// cross-download budget mid-flight. Receives the wanted count, returns the
/// granted count (0...wanted). nil (tests, non-engine callers) disables the
/// mid-flight upgrade entirely.
var requestExtraConnections: (@Sendable (Int) async -> Int)? = nil
```

Both have defaults, so every existing `TransferPlan(...)` call site compiles
unchanged.

### Coordination types (file scope, next to `StreamerBox` :1429)

```swift
/// Trip-once flag between the upgrade prober and the byte pump. A lock, not an
/// actor: the pump reads it at every flush and must not hop executors to do so.
final class UpgradeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isTripped: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}
```

plus, nested in `SegmentedTransfer`: `private struct UpgradeInterrupt: Error {}` —
the pump's cooperative-stop sentinel; it is never a failure.

### Prober (new private members of SegmentedTransfer)

```swift
/// nil when the plan can never upgrade (gate fails, or the engine supplied no
/// budget channel). Caller owns cancellation: `defer { upgrade?.task.cancel() }`.
private func spawnUpgradeProber() -> (task: Task<Void, Never>, signal: UpgradeSignal, total: Int64)?
```

Gate: `plan.requestExtraConnections != nil` AND `shouldAttemptUpgrade(...)` (this
double gate means a plan built without the closure — every existing test — keeps
today's behavior bit-for-bit). Body: unstructured `Task { [plan] in ... }` capturing
only value state (no `self` → no retain cycle); loops `0..<maxAttempts`, sleeping
`initialDelay` first then `interval` (`Task.sleep(nanoseconds:)`, Linux-safe); a
cancelled sleep returns immediately (stream ended first); on a successful probe it
calls `signal.trip()` and exits.

```swift
/// One ranged header probe at the file midpoint. MUST use the openStream +
/// cancelTask pattern (HTTPEngine+Probe.swift:151-155): a server that ignores
/// Range answers 200 with the WHOLE body, and any buffering API would pull it
/// into memory. Headers are all we read.
static func probeMidpointRange(plan: TransferPlan, total: Int64) async -> Bool {
    let box = StreamerBox()
    return await withTaskCancellationHandler {
        var req = makeRequest(plan.url, settings: plan.settings)
        let m = max(0, total / 2)
        req.setValue("bytes=\(m)-\(m)", forHTTPHeaderField: "Range")
        guard let (http, _, streamer) = try? await openStream(
            session: plan.session, request: req,
            // [F4] Close the cancel-vs-register race: a cancellation that fired
            // between the handler install and this registration found a nil box
            // (no-op); re-checking here — synchronously on the prober's task,
            // BEFORE openStream resumes the URLSession task — aborts it so a
            // cancelled prober never leaves a stray midpoint GET waiting on
            // headers (same reason ConnectionGovernor.acquire re-checks under
            // isolation).
            register: { box.set($0); if Task.isCancelled { box.cancel() } }
        ) else { return false }
        streamer.cancelTask()          // headers only — never drain the body
        guard http.statusCode == 206, contentRangeTotal(http) == total else { return false }
        // Probe edge of the validator triangle [F1]: same rule as validatorsAllowResume.
        return validatorsAllowResume(
            cursorETag: plan.etag, cursorLastModified: plan.lastModified,
            probeETag: http.value(forHTTPHeaderField: "ETag"),
            probeLastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    } onCancel: { box.cancel() }
}
```

Decisions:
- The probe uses URLSession (`plan.session`) even for interface-bound plans —
  the engine's initial probe already egresses the default route, so this matches the
  status quo (pins govern payload bytes, not metadata probes).
- The prober is cancelled but **not joined** [F4-partial]: `defer` cannot `await` in
  Swift, and with the register re-check plus `openStream`'s own cancellation handler
  every in-flight probe request is aborted promptly on cancel — the prober task then
  winds down on its own within one continuation resume. Bounded and side-effect-free,
  so a join would add teardown plumbing for nothing.

### Cooperative stop in the pumps

`pumpBody` (:694) gains a trailing parameter `upgrade: UpgradeSignal? = nil`. At the
END of the `buffer.count >= flushSize` branch (after `removeAll`, :715), add:

```swift
// Stop exactly at a flush boundary: `written` then equals the bytes on disk,
// which becomes the upgrade's completed prefix.
if let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
```

Not checked in the tail flush (stream already ended — completion wins). Default nil
keeps `downloadSegment`'s call site (:299) unchanged. `streamSingle` (:629) gains
`upgrade: UpgradeSignal?` and threads it (post [F1] entity-tie gating, above) to its
`pumpBody` call (:673).

[R3] **`UpgradeInterrupt` needs its own catch, with a throwing `handle.close()`.**
The original design reused `streamSingle`'s existing generic `catch` — "cancel the
streamer, treat termination as upgrade, for free" — and that was wrong, because the
generic catch closes with `try? handle.close()`. Swallowing a close failure is the
right call on every other error path there: the transfer is failing anyway and the
partial file is discarded. The upgrade route is the one error path whose on-disk
bytes are **kept**: `ledger.totalBytes()` becomes a completed prefix segment that
`runSegmented` skips via the `segStart > range.end` guard and never re-fetches. A
late write error surfaced only by `close(2)` — the normal shape on NFS/SMB — would
therefore leave a hole inside `[0, W-1]` that no tail segment covers and that the
completeness net cannot see, because that net only sums the ledger. So:

```swift
} catch let interrupt as UpgradeInterrupt {
    streamer.cancelTask()
    try handle.close()          // flush failure = real failure
    throw interrupt
} catch {
    streamer.cancelTask()
    try? handle.close()
    throw error
}
```

The bound twin already used `try handle.close()` on its upgrade branch with exactly
this rationale ("flush failure = real failure"); the two paths are now consistent.
A close failure here surfaces as itself and fails the download instead of producing a
silently corrupt "completed" file.

[F5] Additionally, at the TOP of `streamSingle`'s connect/status retry loop (right
after `try Task.checkCancellation()`, :642), add:

```swift
// A stream stuck in connect/status retries (server 503s the unranged GET while
// happily 206ing ranges) must still honour a trip — nothing has streamed yet,
// so W == 0 and there is no entity edge to verify.
if let upgrade, upgrade.isTripped { throw UpgradeInterrupt() }
```

(The bound path never had this hole: `shouldAbort` is polled by curl's progress
thunk from connect onward.) Accepted residual: a trip that lands while the stream is
mid-body but fully stalled (no further chunk ever arrives) is only observed at the
next flush; that stream is governed by the session's idle timeout, which fails the
single path exactly as today — the upgrade does not race timeouts.

### `runSingle` (:507-531) restructure

```swift
let upgrade = spawnUpgradeProber()
defer { upgrade?.task.cancel() }              // covers completion, failure, cancellation
do {
    try await streamSingle(session: plan.session, limiter: limiter, ledger: ledger,
                           url: plan.url, fileURL: plan.destination, upgrade: upgrade?.signal)
} catch let interrupt as UpgradeInterrupt {
    guard let upgrade else { throw interrupt } // unreachable: interrupt implies a prober
    let written = await ledger.totalBytes()    // == flushed == on-disk bytes
    return try await upgradeToSegmented(total: upgrade.total, written: written)
}
// existing completeness check unchanged
```

Decision: `W = ledger.totalBytes()` — `pumpBody` advances the ledger by exactly the
flushed bytes, so ledger total ≡ on-disk prefix on both single paths; one rule, no
second bookkeeping channel out of `streamSingle`.

### `runSingleBound` (:540-625) restructure

- Spawn the same prober + defer-cancel (after the ledger is created, before the
  attempt loop).
- Thread `shouldAbort: upgrade.map { u in { u.signal.isTripped } }` into
  `BoundHTTPClient.downloadRange` (new parameter, below).
- The existing per-attempt tally pump + trailing drain (:572-585) stays; it already
  makes `ledger.totalBytes() == Response.bytesWritten == on-disk bytes`.
- Replace the aborted branch (:587-590) with the following. [F6] The trip must not
  pre-empt a terminal status, and [F1] the stream edge must hold before mixing:

```swift
if response.aborted {
    // Signal-abort is an upgrade; task-cancellation abort stays a pause/remove.
    // If both raced, cancellation wins — the engine's pause owns the transition.
    if let upgrade, upgrade.signal.isTripped, !Task.isCancelled {
        try handle.close()                       // flush failure = real failure
        let written = await ledger.totalBytes()
        switch Self.classify(response.httpStatus, ranged: false) {
        case .accept:
            // Stream edge of the validator triangle [F1], as amended by [R1].
            // written > 0 implies status 200 (the C thunk drains everything
            // else). The prefix may only be kept if it is provably the probed
            // entity — but a mismatch is NOT a failure, because the probe rides
            // URLSession/gzip while this stream rode curl/identity and origins
            // vary the validator by content-coding. Unprovable prefix =>
            // discard it and refetch [0, total-1] over ranges: still correct,
            // still faster than the single stream it replaces.
            let keepsPrefix = written == 0 || written == upgrade.total
                || Self.validatorsAllowResume(
                    cursorETag: plan.etag, cursorLastModified: plan.lastModified,
                    probeETag: response.etag, probeLastModified: response.lastModified)
            if !keepsPrefix {
                GoelLog.engineHTTP.notice(
                    "Mid-flight upgrade: streamed prefix not provably the probed entity; refetching over ranges",
                    .bytes(written, label: "discarded"),
                    .url(plan.url))
            }
            return try await upgradeToSegmented(
                total: upgrade.total, written: keepsPrefix ? written : 0)
        case .retry:
            // The unranged GET is being 429/5xx'd while ranges just probed 206:
            // upgrading IS the retry. written == 0 (error bodies drain in C).
            return try await upgradeToSegmented(total: upgrade.total, written: written)
        case .reject:
            if response.httpStatus == 0 {
                // Tripped during connect, before any response arrived: nothing
                // on disk (written == 0), no status to honour — upgrade.
                return try await upgradeToSegmented(total: upgrade.total, written: written)
            }
            // [F6] A terminal status (401/403/404…) surfaces as itself instead
            // of being laundered through an upgrade whose segments would re-fail
            // against the same host after a pointless grant/release cycle.
            throw DownloadError.httpStatus(response.httpStatus)
        }
    }
    try? handle.close()
    throw CancellationError()
}
```

Loop-invariant (must hold and does): once tripped, the attempt loop can never spin —
every aborted outcome above returns or throws, and a retry iteration that starts
after a trip is aborted by `shouldAbort` at connect (status 0, `written == 0` since
`canRetry` required `bytesWritten == 0`) and lands in the `.reject`/status-0 upgrade
arm. If curl finished cleanly before the trip, `aborted` is false and normal
completion wins; if the trip landed with `written == total`, the guard in
`upgradeToSegmented` returns a plain completed outcome.

### BoundHTTPClient changes (BoundHTTPClient.swift)

- `TransferContext` (:38): add `let shouldAbort: (@Sendable () -> Bool)?` (init param,
  default nil) and fold it into the `aborted` getter:
  `return _aborted || (shouldAbort?() ?? false)`.
- `downloadRange` (:84): add `shouldAbort: (@Sendable () -> Bool)? = nil`, pass to ctx.
- `Response` (:27-34): add, all with defaults so any direct constructions compile:

```swift
/// 1:1 with GCBHTTPResult.range_ignored: a *ranged* request was answered with a
/// final 200 — the server ignored Range; C aborted before the first body byte.
var rangeIgnored: Bool = false
/// Validators of the final response, captured by the C header thunk ([F1] —
/// the bound path has no HTTPURLResponse to read them from).
var etag: String? = nil
var lastModified: String? = nil
```

- `performBlocking` result construction (:168-177): populate the three new fields
  from the raw struct. Fixed-size C char arrays import into Swift as tuples; convert
  with one helper (file-private in BoundHTTPClient.swift):

```swift
/// GCBHTTPResult's char arrays arrive as homogeneous CChar tuples.
private static func cString<T>(_ tuple: T) -> String? {
    withUnsafeBytes(of: tuple) { buf in
        guard let base = buf.baseAddress else { return nil }
        let s = String(cString: base.assumingMemoryBound(to: CChar.self))
        return s.isEmpty ? nil : s
    }
}
// in the Response(...) construction:
rangeIgnored: raw.range_ignored != 0,
etag: Self.cString(raw.etag),
lastModified: Self.cString(raw.last_modified)
```

- The seek-failure early return (:95-96) keeps compiling via the new defaults.

Folding `shouldAbort` into `aborted` (rather than a separate progress-thunk check)
keeps all three consumers consistent: the write thunk stops writing (:185), the
progress thunk returns 1 → `CURLE_ABORTED_BY_CALLBACK` (:200), and `Response.aborted`
(:174) reads true even if curl completed in the same tick. `downloadSegmentBound`
passes nil — zero behavior change there.

### CurlBridge changes (curl_bridge.h + curl_bridge.c) [F1][F2]

`GCBHTTPResult` (curl_bridge.h:43-49) gains three fields:

```c
int range_ignored;           /* 1: ranged request answered with a final 200 —
                                server ignored Range; aborted before body write */
char etag[256];              /* ETag of the final response, "" if none */
char last_modified[128];     /* Last-Modified of the final response, "" if none */
```

`GCBHTTPResult result = { -1, 0, -1, 0, 0 };` (curl_bridge.c:401) stays as-is — C
aggregate initialization zero-fills the trailing members. A validator longer than
its buffer is truncated by `snprintf`, which can only FAIL the later equality check.

[R1] The original design called that "the safe direction (no upgrade)". It was not
safe as shipped: on the bound path a failed equality check threw
`DownloadError.remoteFileChanged`, so every S3-multipart or long-composite ETag over
256 bytes turned into a permanent, self-repeating download failure rather than a
skipped upgrade. Truncation is only benign now that a failed stream edge discards the
prefix and refetches over ranges instead of throwing (see the amended bound-path
bullet above). The buffers are deliberately left at 256/128: widening them would
shrink the window but cannot close it, since the encoding-variance mismatch this
degradation exists for is unrelated to length.

`struct gcb_http_ctx` (curl_bridge.c:162-175) gains `int range_ignored; char
etag[256]; char last_modified[128];` (zeroed by the existing per-hop `memset`).

`gcb_http_header_thunk` (curl_bridge.c:261-307):
- In the `HTTP/` status-line branch (:271-280), alongside the `location` reset, add
  `ctx->etag[0] = '\0'; ctx->last_modified[0] = '\0';` — a redirect chain must
  surface the FINAL response's validators only.
- After the `Location:` branch, add two parse branches mirroring its shape:

```c
if (strncasecmp(line, "ETag:", 5) == 0) {
    const char *v = line + 5;
    while (*v == ' ' || *v == '\t') v++;
    snprintf(ctx->etag, sizeof(ctx->etag), "%s", v);
    return n;
}
if (strncasecmp(line, "Last-Modified:", 14) == 0) {
    const char *v = line + 14;
    while (*v == ' ' || *v == '\t') v++;
    snprintf(ctx->last_modified, sizeof(ctx->last_modified), "%s", v);
    return n;
}
```

`gcb_http_write_thunk` (curl_bridge.c:211-241) [F2]: between the
`reject_body/range_total_mismatch` return (:226-228) and the drain branch (:233-236),
insert:

```c
/* A final 200 to a *ranged* request means the server ignored Range: the body
   is the whole file and useless to a segment. Abort on the first byte instead
   of draining it — a flapped CDN edge would otherwise cost one full body per
   retry. Redirect hops are followed manually (FOLLOWLOCATION off), so a 200
   here is never an interstitial; the unranged mode is untouched. Returning 0
   yields CURLE_WRITE_ERROR, NOT CURLE_ABORTED_BY_CALLBACK — deliberately, so
   Response.aborted stays false and Swift cannot misread this as a pause. */
if (!ctx->unranged && ctx->http_status == 200) {
    ctx->range_ignored = 1;
    return 0;
}
```

(`write_cb` is not reached, so `Σ onBytes == bytesWritten` still holds and the W3
tally stays 0 on this path. A ranged 200 with an **empty** body never fires the write
thunk: it completes with `rc == CURLE_OK`, `range_ignored == 0`, and falls through
to Swift's classify-reject. [R4] Treating that fall-through as harmless was the
defect: in the upgraded phase Swift's `.reject` case answered it with a terminal
`httpStatus(200)`. The C behavior described here is correct and unchanged — the fix
is entirely on the Swift side, where the `.reject` case now carries the same
`upgraded` retry arm as the URLSession pump. See the amended flap-back section.)

Per-hop result assignment (curl_bridge.c:492-497 region): add

```c
result.range_ignored = ctx.range_ignored;
snprintf(result.etag, sizeof(result.etag), "%s", ctx.etag);
snprintf(result.last_modified, sizeof(result.last_modified), "%s", ctx.last_modified);
```

Do NOT touch `gcb_http_xfer_thunk` for `range_ignored` — a progress-thunk 1 would
surface as `CURLE_ABORTED_BY_CALLBACK` → `Response.aborted == true` → the segment
pump's aborted branch would throw `CancellationError`, which `HTTPEngine` swallows
as its own pause and the task would hang in "Downloading". The write-thunk return 0
fires on the first body chunk, which is prompt enough.

### Flap-back handling in the upgraded phase [F2]

After `upgradeToSegmented` kills the stream, every tail segment issues a ranged GET.
The same cold-edge flap that motivated W2 can answer 200 again; without handling,
`classify(200, ranged: true) == .reject` fails the whole download on the primary,
and the subsequent retry (fresh probe → `acceptsRanges == false` → single stream →
`Data().write`) truncates the W + tail bytes to zero. Mitigation — chosen option (a),
bounded retry, threaded as an `upgraded: Bool` parameter (see the `runSegmented`
refactor below):

- **`downloadSegment`** (:268-279, `.reject` case), before the mirror/primary
  handling:

```swift
if upgraded, http.statusCode == 200, attempt < settings.maxAttempts {
    // Range support flapped back mid-upgrade (cold edge). The probe that
    // triggered this phase just saw a 206, so a warm edge exists; retry with
    // backoff instead of failing a download that was completing without us.
    streamer.cancelTask()                        // never drain the full body
    if isMirror { await pool.demote(url) }
    await governor.release()
    try await backoff(attempt: attempt, response: http, retryInterval: settings.retryInterval)
    continue
}
```

- **`downloadSegmentBound`**: new branch between the `rangeTotalMismatch` handling
  (:408-415) and the curl-error branch (:419) — it must precede the curl-error
  branch because the early abort surfaces as `CURLE_WRITE_ERROR`:

```swift
if response.rangeIgnored {
    // Server ignored Range (flap-back). C aborted on the first body byte, so
    // nothing was written or tallied. Retryable in the upgraded phase (and for
    // mirrors, as the old classify-reject already allowed); terminal 200 on
    // the primary otherwise — identical to today's error, minus the full-body
    // drain the old path paid.
    if isMirror { await pool.demote(url) }
    await adapterGovernors.release(adapter.bsdName)
    await governor.release()
    if (upgraded || isMirror), attempt < settings.maxAttempts {
        try await backoff(attempt: attempt, response: nil, retryInterval: settings.retryInterval)
        continue
    }
    throw DownloadError.httpStatus(200)
}
```

[R4] **The `rangeIgnored` branch does not catch every ranged 200.** C sets
`range_ignored` from the **write** thunk, so a 200 response carrying ZERO body bytes
never invokes it: `range_ignored` stays 0, `rc == CURLE_OK`, and the response falls
through to `classify(200, ranged: true) == .reject`. As shipped that meant a terminal
`DownloadError.httpStatus(200)` that killed the whole upgraded download — an
asymmetry with the URLSession twin, whose `.reject` arm always had the flap retry
(the C flag has no equivalent there; `downloadSegment` reads `http.statusCode`
directly, which is set for an empty body too). The design's own parenthetical noted
that an empty-bodied ranged 200 "falls through to Swift's classify-reject exactly as
today" and treated that as harmless; in the upgraded phase it is not. The same arm is
now present in `downloadSegmentBound`'s `.reject` case, after the release pair and
the 401/403 demote:

```swift
if upgraded, status == 200, attempt < settings.maxAttempts {
    if isMirror { await pool.demote(url) }
    try await backoff(attempt: attempt, response: nil,
                      retryInterval: settings.retryInterval)
    continue
}
```

The two segment pumps are now symmetric on flap-back: body-carrying ranged 200s take
the `rangeIgnored` branch (no full-body drain), empty ones take this one, and both
retry with backoff in the upgraded phase.

Behavior in the NON-upgraded segmented phase is preserved on the primary: primary
flap → `httpStatus(200)` after one attempt (as today, but without draining the body).

[R6] **Accepted deviation — mirror flap-back retry latency on the bound path.** The
original text claimed "mirror flap → demote + retry (as today)". Verified against
`git show main:Sources/GoelCore/Engine/SegmentedTransfer.swift`, that is false. On
`main` a ranged-200 mirror flap landed in `downloadSegmentBound`'s `.reject` case and
retried IMMEDIATELY:

```swift
if isMirror, attempt < settings.maxAttempts {
    await pool.demote(url)
    continue                      // no backoff
}
```

A body-carrying flap now takes the new `rangeIgnored` branch instead, whose retry arm
is gated `(upgraded || isMirror)` and sleeps `backoff(attempt:)` before `continue`.
Retry latency for a bound mirror flap therefore changed from zero to one backoff
interval. Accepted rather than reverted: a flapping edge answered with a hot retry
loop is strictly worse-behaved than one answered with backoff, and the demote already
moved the segment off that mirror, so the sleep costs latency on a path that was
about to be abandoned anyway. Two things are unchanged and were checked: the
URLSession pump (`downloadSegment`) still retries a non-upgraded mirror reject with
no backoff, and the empty-bodied bound case still reaches the old no-backoff
`isMirror` arm below the [R4] branch — so the deviation is scoped to bound mirrors
answering a ranged request with a 200 that carries a body.

Documented residual (accepted): if the flap persists through a segment's whole
attempt budget, the upgraded phase fails with a resume cursor whose next fresh
probe may again hide ranges, dropping init to single-stream and truncating the
partial file — the pre-existing rule for ANY segmented download whose re-probe
loses range support (init discards the cursor, `Data().write` truncates). Fixing
that generally requires unranged skip-ahead resume machinery (rejected below).
W2 narrows the exposure: the retry budget must be exhausted by consecutive flaps
first, and the re-run's own prober will upgrade again once edges warm.

### Pure layout function (near the range math, :731)

```swift
/// Layout for a single stream upgrading to segments: a completed prefix
/// [0, written) restored as segment 0 (omitted when nothing was flushed), and
/// the remainder cut with the same clamp math a fresh plan would use.
static func upgradedLayout(total: Int64, written: Int64, connections: Int,
                           minSegment: Int64 = 64 * 1024) -> (ranges: [Range64], restored: [Int: Int64]) {
    let remainder = max(0, total - written)
    let count = clampSegmentCount(max(1, connections), total: remainder, minSegment: minSegment)
    let tail = makeRanges(total: remainder, count: count)
        .map { Range64(start: $0.start + written, end: $0.end + written) }
    guard written > 0 else { return (tail, [:]) }
    return ([Range64(start: 0, end: written - 1)] + tail, [0: written])
}
```

(`remainder == 0` → `makeRanges` returns `[]` → prefix-only layout; well-formed.)

### Transition (new private method)

```swift
private func upgradeToSegmented(total: Int64, written: Int64) async throws -> TransferOutcome {
    if written == total {
        // The trip landed on the stream's final flush: nothing left to segment.
        return TransferOutcome(bytesWritten: written, resumeData: nil, usedSegments: 1)
    }
    // [F3] The streamed 200 is a separate response with its own framing and can
    // be LONGER than the probed size (mid-deploy: edge A declared 10 MiB/v1,
    // edge B streamed 12 MiB/v2). Success is written == total ONLY; an
    // overshoot must fail exactly like runSingle's completeness net — never be
    // returned as `.completed`, and never reach preallocate (which would
    // truncate real bytes).
    guard written < total else {
        throw DownloadError.network("Incomplete download: wrote \(written) of \(total) bytes")
    }
    try Task.checkCancellation()                 // don't charge budget for a paused task
    let multiPath = plan.boundAdapters.count >= 2
    let minSegment: Int64 = multiPath ? 32 * 1024 : 64 * 1024
    let sizeCap = Self.clampSegmentCount(Self.upgradeMaxConnections,
                                         total: total - written, minSegment: minSegment)
    let granted = await plan.requestExtraConnections?(max(0, sizeCap - 1)) ?? 0
    let layout = Self.upgradedLayout(total: total, written: written,
                                     connections: 1 + granted, minSegment: minSegment)
    let streams = layout.ranges.count - (written > 0 ? 1 : 0)
    GoelLog.engineHTTP.notice("Range support appeared mid-download; upgrading to segmented",
        .count(streams, label: "connections"),
        .bytes(written, label: "written"),
        .bytes(total, label: "total"),
        .url(plan.url))
    return try await runSegmented(total: total, ranges: layout.ranges,
                                  restored: layout.restored, upgraded: true)
}
```

Decisions:
- The transfer asks for `sizeCap - 1` extras (it already holds 1 reserved
  connection); the ENGINE owns profile/host/global clamping inside the closure — the
  transfer never learns profile internals.
- A zero grant still upgrades (1 tail segment): the download becomes resumable with
  cursors, which single-stream never was.
- `layout.connections = 1 + granted` — never inflated to `boundAdapters.count`; opening
  more segments than the budget charged would falsify the engine's accounting. If
  granted < adapters−1, a NIC idles; budget correctness wins.
- EngineEvent: **log-only**. No existing event fits ("upgraded") without new UI
  plumbing; the existing `.progress.connectionCount` and `.connectionsUpdated` rows
  already show the fan-out jump, per the work item's "if none fits, log-only".
  [F10-partial] Accepted staleness: the Details tab keeps showing the pre-transfer
  `.remoteInfoResolved` (`Accept-Ranges: no`) after an upgrade — re-emitting it would
  require an engine-event channel the transfer deliberately does not have.

### Refactor prerequisite: `runSegmented(total:ranges:restored:upgraded:)`

- Signature: `private func runSegmented(total: Int64, ranges: [Range64], restored:
  [Int: Int64], upgraded: Bool) async throws -> TransferOutcome`.
- `run()` (:123) passes `runSegmented(total: total, ranges: plannedRanges,
  restored: restoredBytes, upgraded: false)`.
- Inside, `let ranges = plannedRanges` (:144) is deleted and `initialBytes` (:147-149)
  becomes the normalization (behaviorally identical for both existing callers):

```swift
let initialBytes = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, restored[$0] ?? 0) })
```

- `upgraded` is threaded into `downloadSegment` and `downloadSegmentBound` (the [F2]
  flap-retry gate) and read in one more place, [R2] below.
- [R2] **An upgraded transfer stays on the primary URL.** The `MirrorPool` is built
  `MirrorPool(primary: plan.url, mirrors: upgraded ? [] : plan.mirrors)`. The original
  design left the pool untouched, which was wrong: mirrors are admitted on the
  strength of a matching `Content-Range` total alone. That is an acceptable bar when
  every byte of the file comes from the pool — size agreement plus the per-segment
  checks is all a fresh segmented download ever had. It is not acceptable after an
  upgrade, because bytes `[0, W-1]` are already on disk **from the primary stream**,
  and BOTH edges of the validator triangle ([F1]: probe↔plan and stream↔plan) were
  checked against the primary only. A same-sized but differently-contented mirror —
  an in-place `rsync`, a staggered release, a stale edge — would splice two entities
  into one file, pass the completeness net, and report `.completed`. Suppressing
  mirrors also preserves what `TransferPlan.mirrors`' own doc comment already
  promised: a download that started single-stream stays on the primary. Cost, owned:
  no mirror fan-out for upgraded downloads. The alternative — re-running the
  validator triangle against each mirror before admitting it — was rejected: it needs
  a per-mirror probe round-trip on the transfer's critical path, and the mirror
  admission bar is a pre-existing question that does not belong to W2.
- Everything else in the function is source-identical, so the upgrade path inherits:
  `Self.preallocate(plan.destination, size: total)` (:145) — `truncate(atOffset:)`
  EXTENDS the W-byte file to `total`, preserving the prefix (the upgrade path never
  touches `Data().write` again — that only runs at the top of the single paths,
  before streaming, and [F3] guarantees `written < total` so preallocate can only
  grow the file); a FRESH `Ledger` seeded with `restored` (runningTotal starts at
  W → reported `bytesDownloaded` stays monotonic across the transition, on the same
  `continuation`); a `CursorMeta` built from plan validators + the synthesized ranges
  → 1 Hz resume cursors start flowing where the single stream had none; and when
  `plan.boundAdapters` is non-empty, `downloadSegmentBound` across ALL adapters via
  `AdapterPool` — this is what turns a one-connection download into an aggregated one.
- The completed prefix segment is skipped by the existing `segStart > range.end`
  guard (:180); its W bytes count toward the completeness net.
- `connectionCount` in progress ticks reports `ranges.count` (includes the finished
  prefix) — same quirk the resume path already has; kept for consistency.

### HTTPEngine wiring (HTTPEngine.swift :529-558)

`let plan` (:529) becomes `var plan`; immediately after the initializer, before
`PlannedTransfer(plan:)` (:547):

```swift
let extraGrants = ExtraGrantCounter()
plan.requestExtraConnections = { [weak self] wanted in
    guard let self, wanted > 0 else { return 0 }
    let granted = await self.grantExtraConnections(host: host, wanted: wanted)
    extraGrants.add(granted)
    return granted
}
```

(Attached unconditionally — the transfer's gate is authoritative; plans built
directly in tests default to nil and are unaffected.)

The reservation block (:556-558) becomes:

```swift
let reserved = planned.connectionCount
reserveConnections(host: host, count: reserved)
// Balance to zero on EVERY exit: initial reservation + every mid-flight grant.
defer { releaseConnections(host: host, count: reserved + extraGrants.total) }
```

New in HTTPEngine+Transfer.swift:

```swift
/// Mid-flight grants recorded outside the actor: the closure is @Sendable while
/// the balancing defer runs actor-isolated; the lock is the bridge.
final class ExtraGrantCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { guard n > 0 else { return }; lock.lock(); count += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// on HTTPEngine (actor-isolated):
/// Charge up to `wanted` extra connections for a running download (W2 upgrade).
/// Raw room, no floor-of-1: the download already holds a connection, so zero is
/// an honest answer here (the initial planner's floor exists so a NEW download
/// never stalls — that rationale does not apply mid-flight).
func grantExtraConnections(host: String?, wanted: Int) -> Int {
    let grant = min(max(0, wanted), connectionBudget.extraRoom(host: host, profile: profile))
    guard grant > 0 else { return 0 }
    connectionBudget.reserve(host: host, count: grant)
    return grant
}
```

New in ConnectionBudget.swift (pure, testable):

```swift
/// Room for MID-FLIGHT extras: min of per-host and global free slots, floored at
/// 0 (not 1 — see grantExtraConnections). Low profile grants nothing.
func extraRoom(host: String?, profile: TrafficProfile) -> Int {
    guard profile.enableExtraConnections else { return 0 }
    let hostFree = profile.maxConnectionsPerServer - hostInUse(host)
    let globalFree = profile.maxConnections - totalConnections
    return max(0, min(hostFree, globalFree))
}
```

### Budget balance — every exit path of the upgrade flow

| Path | Charged | Released |
|---|---|---|
| Single stream completes/fails before any grant | reserved (1) | defer: 1 + 0 |
| Upgrade, grant g, clean completion | 1 + g | defer: 1 + g |
| Upgrade, grant g, failure in segmented phase (incl. exhausted [F2] flap retries) | 1 + g | defer: 1 + g |
| Pause/remove during upgraded phase | 1 + g | job cancel → run() unwinds → defer: 1 + g |
| Pause racing the grant call | grant completes on the actor and is recorded in `extraGrants` before `requestExtraConnections` returns; the transfer then hits `Task.checkCancellation` / governor acquire and unwinds | defer: 1 + g |
| Bound trip declined ([F6] terminal status → throw) | 1 (closure never called — the throw precedes it) | defer: 1 + 0 |
| [R1] Bound stream-edge mismatch (prefix discarded, `written` forced to 0) | 1 + g — this is an ordinary upgrade, not a decline; the grant happens exactly as on the `keepsPrefix` path | defer: 1 + g |
| Overshoot throw [F3] | 1 (throw precedes the grant call) | defer: 1 + 0 |
| Engine gone (`weak self` nil) | closure returns 0, nothing charged | defer: 1 + 0 |
| Grant = 0 | 1 | defer: 1 |

The closure is only ever invoked from the transfer's main task (inside
`upgradeToSegmented`), never from the prober task — so every grant strictly
happens-before `planned.run()` returns, which strictly happens-before the defer.
At most one upgrade per run (the segmented phase is terminal and the prober is
cancelled by the singles' defers), but the counter would stay correct even if not.

### Resume-cursor behavior across the upgrade

- **Before**: single stream → `Ledger(meta: nil)` → `maybeResume` returns nil → no
  cursor, `streamedResume` empty; pause restarts from zero (status quo).
- **During transition**: between the interrupt and the upgraded ledger's first 1 Hz
  tick there is still no cursor; a pause in that sub-second window restarts. Accepted:
  the window is bounded by one flush + one tick, and the alternative (synchronously
  pushing a cursor through the progress stream) adds a channel for a corner case.
- **After**: cursors carry the synthesized ranges with `completed[0] == W` (+ live
  tail progress) and the plan's validators. On resume, `init`'s existing cursor path
  accepts them: `cursorIsWellFormed` holds by construction, the multi-path
  stale-cursor guard (:81-82) passes because `completed[0] = W ≠ 0`, and
  `destinationHoldsPreallocation` holds because the upgraded phase preallocated to
  `total`. If the re-probe still hides ranges (`acceptsRanges == false`), init drops
  to single-stream and the cursor is discarded — pre-existing rule, and W2 will
  simply probe and upgrade again.
- [F7] Edge, comment-only: an upgraded phase that started with `W == 0` (a
  connect-phase or pre-first-flush trip — possible on BOTH paths after [F5]) and
  `granted == 0` writes a 1-range cursor with `completed == [0]`; on resume with
  ≥ 2 bound adapters the multi-path stale-cursor guard (init :81-82) rejects it and
  restarts. Harmless — nothing was on disk — but add one sentence to that guard's
  comment noting the upgraded phase now legitimately produces single-range cursors,
  so the rejection is not misread as a bug.

### Cancellation analysis — every new await point

- Prober `Task.sleep`: throws on cancel → prober returns; cancelled via
  `defer { upgrade?.task.cancel() }` on all exits of both singles.
- `probeMidpointRange`'s `openStream`: cancellation handler aborts the URLSession
  task through `StreamerBox` → continuation resumes throwing → `try?` → false; the
  [F4] register re-check closes the install-vs-register gap, so a pre-registration
  cancel aborts the task before `resume()` instead of waiting on headers. No
  stranded connection, no stranded continuation, no stranded Linux `StreamRouter`
  entry (removed on `didCompleteWithError`).
- `pumpBody`'s new check: pure lock read; the throw path reuses the existing
  mid-body-error teardown (streamer cancelled, handle closed).
- `plan.requestExtraConnections`: actor hop with no cancellation check by design —
  a grant that lands on a just-cancelled task is still recorded and still released
  by the defer (table above).
- `runSegmented` from the upgrade path: children check cancellation at
  `governor.acquire` → CancellationError → group unwinds → propagates to `run(id)`'s
  existing catch. Identical to a fresh segmented run.

---

## W3 — Bound-path live progress + pause-safe partial commit + reason surfacing

### `downloadSegmentBound` tally pump (SegmentedTransfer.swift :395-399, :419-433, :470-475)

Per attempt, exactly the `runSingleBound` pattern (:572-585):

```swift
// curl's write callback cannot await; it tallies and this pump folds the bytes
// into the ledger every 200 ms so progress ticks — and the 1 Hz resume cursor —
// reflect what is already on disk mid-attempt.
let tally = ByteTally()
let pump = Task { [tally] in
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 200_000_000)
        let n = tally.drain()
        if n > 0 { await ledger.advance(segment: index, by: n) }
    }
}
let response = await BoundHTTPClient.downloadRange(
    boundReq, file: handle, fileOffset: UInt64(segStart), limiter: limiter,
    onBytes: { [tally] in tally.add($0) })
pump.cancel()
_ = await pump.value
let trailing = tally.drain()
if trailing > 0 { await ledger.advance(segment: index, by: trailing) }
```

The drain completes before ANY branching, so the ledger is fully credited before
retry offsets are computed. Then **remove** both post-hoc bulk credits:

- curl-error path (:422): delete `await ledger.advance(segment: index, by: Int(response.bytesWritten))`, keep `written += response.bytesWritten`.
- success path (:473): same deletion, keep `written +=`.

Why this cannot double- or over-count (verified against curl_bridge.c, including the
new [F2] branch):
- Error/redirect bodies (429/5xx/3xx) are drained in C without reaching the write
  callback → tally 0 on `.retry`/`.reject`.
- The ranged-200 early abort ([F2]) returns 0 BEFORE `write_cb` → tally 0,
  `bytesWritten` 0 on the `rangeIgnored` path.
- Content-Range mismatch/missing (with `expectedTotal` — always set here, :392) sets
  `reject_body` before the first body byte → `bytesWritten == 0`, tally 0 on the
  `rangeTotalMismatch` path. (The Swift-side belt at :459-468 therefore can never
  fire with tallied bytes; it stays as a belt.)
- `onBytes` fires only after `handle.write` succeeded → tally ≡ bytes on disk,
  and `written` (from `response.bytesWritten`) stays ≡ the ledger's per-attempt
  credit, so retry-resume offsets and the completeness net are unchanged.

Consequence, for free: on pause/abort (:401-404) the throttled ticks already carried
the partial bytes into `streamedResume`'s cursor — the old "throw CancellationError
without credit" byte loss disappears.

### Reason surfacing (HTTPEngine.swift, after :504 `let boundAdapters = ...`)

[F10] The wording must not promise a re-probe the gate would refuse; compute the
gate's answer and say only what is true:

```swift
if boundAdapters.count >= 2, !canSegment {
    // ≥2 NICs resolved but the server hid range support: aggregation cannot
    // start. The mid-flight prober (W2) watches only when a size + validator
    // exist, so surface exactly what will happen instead of an idle-NIC mystery.
    let willReprobe = SegmentedTransfer.shouldAttemptUpgrade(
        totalBytes: probe.totalBytes, acceptsRanges: probe.acceptsRanges,
        etag: probe.etag, lastModified: probe.lastModified)
    GoelLog.engineHTTP.notice("Aggregation unavailable: server does not support ranged requests",
        .host(host ?? "unknown"),
        .count(boundAdapters.count, label: "adapters"),
        .flag(willReprobe, label: "willReprobeMidDownload"))
}
```

(The "server does not support ranged requests" clause is accurate at this site: both
probe interpreters force `acceptsRanges == false` whenever `totalBytes == nil`, so
`canSegment == probe.acceptsRanges` here.)

---

## Decision log (ambiguities resolved)

1. `AdapterGovernors` = immutable map of `ConnectionGovernor` actors, not a new actor
   — inherits proven cancellation machinery; key set is fixed at init.
2. Unknown adapter key in `AdapterGovernors` is a no-op — bookkeeping must never
   deadlock a pump; the key set makes it unreachable anyway.
3. Global governor is never throttled in multi-path — per-IP pushback belongs to the
   adapter that received it; aggregate ceiling remains `ranges.count`. [F9] Owned
   trade-off: a per-credential rate limiter now sees sustained pressure from healthy
   NICs (each adapter governor still converges down on its own 429s); this is a
   feature of the per-source-IP model, not a bug.
4. Upgrade prober double-gated on `requestExtraConnections != nil` — plans without
   the engine channel (all existing tests) behave bit-identically to today.
5. Upgrade probe uses URLSession, not `BoundHTTPClient` — the initial probe already
   egresses unbound (status quo: pins govern payload bytes, not metadata probes).
6. Signal-abort rides `TransferContext.aborted` (progress thunk →
   `CURLE_ABORTED_BY_CALLBACK`) — a write-thunk 0 would be misread as transport error.
   Mirror rule [F2]: the ranged-200 abort rides the WRITE thunk precisely so it is
   NOT `aborted` and cannot be misread as a pause.
   *(Partially corrected by 29: the decision — fold `shouldAbort` into
   `TransferContext.aborted` — is unchanged and correct, but the parenthetical
   rationale is not. Because `aborted` re-reads the closure, a mid-body trip normally
   stops curl through the WRITE thunk and is still reported as `aborted`. The mirror
   rule for [F2] survives intact: that abort is set inside C without touching
   `ctx.aborted`.)*
7. `W = ledger.totalBytes()` on both single paths — ledger ≡ flushed ≡ on-disk by
   construction; no second bookkeeping channel.
8. Transfer requests `sizeCap − 1` extras (cap 32, mirrors `multiPathSegmentCount`);
   engine clamps by profile/budget inside the closure — no profile knowledge leaks
   into the transfer.
9. Zero grant still upgrades — a resumable 1-segment download beats an unresumable
   stream.
10. Upgraded fan-out = `1 + granted`, never inflated to adapter count — budget
    truthfulness beats per-NIC floor; an idle NIC is acceptable.
11. `extraRoom` floors at 0, not 1 — the mid-flight download already owns a
    connection; the initial planner's floor rationale doesn't apply.
12. Upgrade announcement is log-only — no `EngineEvent` fits; `connectionCount` in
    existing progress events already surfaces the change to the UI. [F10] The
    Details tab's stale `Accept-Ranges: no` after an upgrade is accepted staleness.
13. Pause beats upgrade when both race the bound abort — the engine's pause owns the
    state machine.
14. Probe cadence lives on `TransferPlan` (`UpgradeProbing`) — testable without
    shared mutable statics; production defaults 10 s / 30 s / 5 unchanged.
15. Grant closure called only from the transfer's main task — every grant
    happens-before the engine's balancing defer, structurally.
16. Cursor-less sub-second window during the transition accepted — bounded by one
    flush + one tick; avoids a new synchronous cursor channel.
17. `downloadSegmentBound` uses a per-attempt `ByteTally` — exact per-attempt
    accounting for retry offsets, mirroring `runSingleBound`'s pump verbatim.
18. [F1] Validator triangle has TWO required edges (probe↔plan and stream↔plan),
    both via `validatorsAllowResume`. URLSession path checks the stream edge before
    arming the pump (mismatch = stream completes untouched); bound path checks it
    after the abort using C-captured validators (mismatch with W > 0 =
    `remoteFileChanged`, a visible coherent failure). Restricting the bound upgrade
    to W == 0 was rejected — it would gut the bound upgrade entirely.
    **Superseded by 25 on the bound half only.** The two-edge requirement stands and
    the URLSession half is unchanged; the bound half's `remoteFileChanged` throw was
    a defect and is now a prefix discard + ranged refetch.
19. [F2] Flap-back mitigation = bounded retry (existing per-segment attempt budget,
    normal backoff), gated on the new `upgraded` flag; plus the C ranged-200 early
    abort so bound retries never pay a full-body drain. Residual truncate-on-restart
    after exhausted retries is the pre-existing lost-range-support rule; accepted.
    *(Extended by 28: the C flag alone does not cover an empty-bodied ranged 200, so
    the bound `.reject` case needs the same retry arm the URLSession pump always had.
    Deviation logged in 30.)*
20. [F3] `upgradeToSegmented` succeeds only on `written == total`; `written > total`
    throws the same completeness error `runSingle` uses. Overshoot can never reach
    `preallocate`.
21. [F4] Prober is cancelled, never joined — `defer` cannot await; the register
    re-check plus the openStream cancel handler already abort any in-flight probe
    promptly.
22. [F5] `streamSingle` checks the trip at the top of its connect/status retry loop
    (W == 0 there, so no entity edge needed). A mid-body fully-stalled stream is
    left to the session idle timeout — the upgrade does not race timeouts.
23. [F6] On the bound path a trip never launders a terminal reject status: 401/403/
    404… surface as `httpStatus`; retryable statuses and status-0 (connect-phase)
    trips upgrade with W == 0.
24. C validator buffers (256/128) truncate long headers via `snprintf` — truncation
    can only fail the equality check, i.e. refuse the upgrade: fail-closed.
    **Premise corrected by 25.** As shipped, a failed equality check on the bound
    path did not "refuse the upgrade" — it threw `remoteFileChanged` and failed the
    whole download, so a long S3-multipart ETag was fail-*open* in the worst sense.
    The buffers stay at 256/128; truncation is genuinely benign only under 25.

### Post-review fixes (25–30)

25. [R1] A failed bound-path stream edge discards the prefix and refetches
    `[0, total-1]` over ranges (`upgradeToSegmented(total:written: 0)`) instead of
    throwing `DownloadError.remoteFileChanged`; `written == 0` and
    `written == upgrade.total` short-circuit ahead of the validator call. Rejected
    alternative: keep the throw (the shipped behavior). It was unsound because the
    two edges observe different representations by construction — the probe rides
    URLSession/gzip, every bound request rides curl with `Accept-Encoding: identity`
    (curl_bridge.c:413), and encoding-varying origins (Apache `mod_deflate`'s `-gzip`
    suffix, nginx/Cloudflare weakening) return a different-but-equivalent ETag. The
    throw therefore failed downloads that completed fine before the feature existed,
    and did not self-heal: the retry re-probes to the same unranged verdict and trips
    again. Also rejected: suppressing the upgrade and letting the stream continue —
    impossible, the trip has already stopped curl and an unranged stream cannot
    resume. Discarding is correct (every byte then comes from the one ranged entity)
    and still buys the fan-out. Side effect: makes decision 24's fail-closed claim
    true, so long/truncated ETags now degrade to a refetch instead of a hard failure.
26. [R2] `runSegmented` builds its `MirrorPool` with `mirrors: upgraded ? [] :
    plan.mirrors` — an upgraded transfer stays on the primary. Rejected alternative:
    leave the pool as-is (the shipped behavior), which would let a same-sized but
    differently-contented mirror supply the tail under a primary-sourced prefix and
    still report `.completed`; mirrors are admitted on a `Content-Range` total alone,
    and both validator-triangle edges were checked against the primary only. Also
    rejected: re-run the triangle per mirror before admitting it — a probe round-trip
    on the critical path for a mirror-admission question that predates W2. Cost owned:
    no mirror fan-out for upgraded downloads. Bonus: restores the guarantee
    `TransferPlan.mirrors`' doc comment already made.
27. [R3] `streamSingle` catches `UpgradeInterrupt` in its own arm and closes the
    handle with `try handle.close()`. Rejected alternative: reuse the generic catch
    (the shipped design), whose `try? handle.close()` is correct for every path that
    throws away the partial file but not for the one path that KEEPS it — the prefix
    becomes a completed ledger segment `runSegmented` never re-fetches, so a
    swallowed `close(2)` write error (NFS/SMB) leaves a hole inside `[0, W-1]` that
    the ledger-summing completeness check is blind to. The bound twin already applied
    "flush failure = real failure"; the two paths are now consistent.
28. [R4] `downloadSegmentBound`'s `.reject` case gains the same upgraded ranged-200
    retry arm `downloadSegment` always had. Rejected alternative: rely on the C
    `range_ignored` flag alone (the shipped design). C only sets it from the write
    thunk, so a 200 with a zero-byte body never trips it and reached a terminal
    `httpStatus(200)`, killing an entire upgraded download over a flap the URLSession
    pump would have retried. Also rejected: set `range_ignored` from the header thunk
    instead — that would fire before the body is known to be empty and duplicates a
    decision Swift can already make from `status == 200 && ranged`.
29. [R5] The comment above `shouldAbort` in `runSingleBound` (and the ground-truth
    bullet that seeded it) claimed the trip's "only abort channel" is the progress
    thunk yielding `CURLE_ABORTED_BY_CALLBACK`. Corrected to state what the code
    does: `shouldAbort` is folded into `TransferContext.aborted`, which the write
    thunk also reads (returning 0 → `CURLE_WRITE_ERROR`), so a mid-body trip normally
    stops curl through the WRITE thunk while `Response.aborted` still reads true
    because it re-reads the closure. Comment-only — no behavior changed, and none
    needed to: the design's decision to fold `shouldAbort` into `aborted` is exactly
    what makes both channels equivalent. Rejected alternative: leave it, since it is
    "functionally harmless" — a wrong stated invariant is what the next reader will
    reason from, and this one would argue against the write-thunk path being safe.
30. [R6] Accepted deviation, no code change: a ranged-200 mirror flap on the bound
    path now sleeps a backoff before retrying, where `main` retried immediately
    (`await pool.demote(url); continue` in the old `.reject` case). Cause: a
    body-carrying flap is now routed to the new `rangeIgnored` branch, whose retry
    arm is `(upgraded || isMirror)`-gated and calls `backoff(attempt:)` first. This
    contradicts DESIGN's earlier "mirror flap → demote + retry (as today)"; the claim
    was wrong, not the code. Accepted rather than reverted: a flapping edge answered
    with backoff is strictly better-behaved than a hot retry loop, and the demote has
    already moved the segment off that mirror. Scope verified: `downloadSegment`
    (URLSession) is unaffected, and an empty-bodied bound flap still reaches the old
    no-backoff `isMirror` arm.

---

## Unit tests for the Test phase

Harness additions to `StubURLProtocol` (HTTPEngineTests.swift:14-149) — all new
`Config` fields default off and all static knobs are cleared inside `set(_:)`, so
every existing test is untouched:

- `Config.holdUnrangedBodyAt: Int? = nil` — while delivering an UNRANGED 200 body,
  after ≥ this many bytes, spin (`while !released && !stopped { usleep(10_000) }`)
  until `releaseUnrangedBody()` is called. This is the [F8] determinism fix: the
  stream physically cannot finish before the test has observed the probe and
  released it, so the trip-vs-completion race is gone.
- `static func releaseUnrangedBody()` / internal released flag (cleared by `set`).
- `Config.unrangedData: Data? = nil` — when set, unranged 200s serve THIS body (with
  its own Content-Length) while ranged GETs keep serving `data`. Lets tests express
  probe-vs-stream asymmetry (overshoot [F3], stream-entity mismatch [F1]).
- `Config.unrangedETagOverride: String? = nil` — when set, unranged 200s carry this
  ETag instead of `etag` (stream-edge mismatch [F1]).
- `static func seenRangeHeaders() -> [String]` — every `Range` header observed
  (cleared by `set`); the midpoint probe is identified as `"bytes=M-M"` with
  `M = total/2`.
- `static func force200ForMultiByteRangedGETs(_ n: Int)` — answer the next n ranged
  GETs whose range spans MORE than one byte with a full 200 body (flap-back [F2]);
  single-byte ranges (the midpoint probe) are exempt so the knob cannot eat the trip.

**New: Tests/GoelCoreTests/AdapterGovernorsTests.swift**
- `testStartsWideOpenAdmitsFullFanOutPerAdapter` — limit N, two adapters: N
  immediate acquires on each adapter succeed without parking (the
  behavior-identical-until-429 guarantee).
- `testThrottleDownShrinksOnlyTheTargetAdapter` — throttle "en0" to 1: a second
  "en0" acquire parks (flag not set within a short wait) while "en1" still admits
  its full fan-out; a release admits the parked waiter.
- `testAcquireCancellationDequeuesParkedWaiter` — fill "en0", park a waiter in a
  Task, cancel it: it throws `CancellationError`; a subsequent release + acquire
  proves slot accounting is intact (no leaked reservation).
- `testUnknownAdapterKeyIsNoOp` — acquire/release/throttleDown on an unknown key
  return immediately, never trap or hang.

**New: Tests/GoelCoreTests/MidflightUpgradeTests.swift** (StubURLProtocol harness,
same plan-building helpers as SegmentedTransferTests)
- `testShouldAttemptUpgradeRequiresSizeNoRangesAndValidator` — false for: nil total,
  total < 8 MiB, acceptsRanges true, no validators; true for 8 MiB + etag-only and
  + lastModified-only.
- `testUpgradedLayoutPrefixPlusRemainderSplit` — total 100 MiB, W 10 MiB, conns 4:
  ranges[0] == [0, W−1], restored == [0: W], 4 contiguous tail ranges covering
  [W, total−1] gap-free.
- `testUpgradedLayoutOmitsPrefixWhenNothingFlushed` — W 0: no prefix range, empty
  restored, tail covers [0, total).
- `testUpgradedLayoutClampsByMinSegment` — remainder 100 KiB, conns 8: 2 tail ranges
  at the 64 KiB floor; 4 at the 32 KiB multi-path floor.
- `testUpgradedLayoutZeroRemainder` — W == total: prefix-only layout, restored [0: W].
- `testMidflightUpgradeCompletesSegmentedWithPrefixIntact` [F8, deterministic] —
  16 MiB payload, etag `"\"v1\""` on stub AND plan, plan `acceptsRanges: false`,
  stub `supportsRanges: true` (cold-probe/warm-now), `chunkSize: 64 KiB`,
  `chunkDelayMicros: 2000`, `holdUnrangedBodyAt: 1 MiB`, plan `flushSize: 64 KiB`,
  `upgradeProbing(initialDelay: 0.05, interval: 0.1, maxAttempts: 10)`,
  `requestExtraConnections` returning 3 and recording its `wanted` + call count.
  Flow: start `run()` in a Task; poll `seenRangeHeaders()` until the midpoint probe
  (`"bytes=8388608-8388608"`) was served; sleep 0.2 s (trip is local, lands in ms;
  and every later flush re-checks, with ≥ 0.4 s of stream left post-release, so even
  a late trip cannot be missed); `releaseUnrangedBody()`; await outcome. Asserts:
  closure called once with `wanted ≥ 1`; outcome `usedSegments > 1`; `resumeData`
  non-nil, decodes to a cursor whose ranges[0].start == 0 and `completed[0] > 0`;
  max `connectionCount` over ticks > 1; `bytesDownloaded` ticks monotonic; file
  bytes == payload byte-for-byte (prefix preserved through `preallocate`).
- `testUpgradeSkippedWithoutValidator` — same shape but stub + plan etag nil and NO
  hold (the gate refuses, so nothing would ever release a held body): closure never
  called, `usedSegments == 1`, file correct.
- `testUpgradeRejectedWhenProbeValidatorsChanged` — plan etag `"\"v1\""`, stub serves
  `"\"v2\""`, `holdUnrangedBodyAt: 1 MiB`: poll until ≥ 1 midpoint probe was served,
  release, await: probe's 206 fails the probe edge; closure never called; completes
  single-stream with the file correct.
- `testUpgradeDisabledWhenStreamEntityDiffers` [F1] — stub etag `"\"v1\""` (ranged +
  probe), `unrangedETagOverride: "\"v2\""`, plan etag `"\"v1\""`, hold at 1 MiB:
  poll until the midpoint probe was served (it 206s with v1 → trip fires), release;
  the pump never interrupts (stream edge failed) → closure never called,
  `usedSegments == 1`, file == payload.
- `testUpgradeOvershootFailsInsteadOfCompleting` [F3] — `data`: 9 MiB (ranged/probe
  view, matches plan `totalBytes: 9 MiB`), `unrangedData`: 12 MiB, hold at 10 MiB,
  plan etag matching: after probe + release, the first flush past the hold sees the
  trip with `written ≥ 10 MiB > total` → `run()` throws `DownloadError.network`
  containing "wrote"; closure never called (throw precedes the grant).
- `testUpgradedPhaseRetriesRangedTwoHundredFlapback` [F2, URLSession path] — the
  deterministic upgrade shape above plus `force200ForMultiByteRangedGETs(2)` set at
  test start (probe exempt by construction): two upgraded segment attempts get 200,
  retry with backoff, then 206 — outcome completes, file intact, closure called once.

**Additions: ConnectionBudgetTests.swift**
- `testExtraRoomUsesRawRoomWithoutFloorOne` — a saturated host/global budget yields
  0 (not 1); partially used budgets yield `min(hostFree, globalFree)`.
- `testExtraRoomZeroWhenProfileForbidsExtraConnections` — `.low` profile → 0
  regardless of room.

**Additions: BoundHTTPClientTests.swift** (loopback `serveOnce` harness)
- `testOnBytesTallyMatchesBytesWritten` — loopback 200 with a 64 KB body:
  Σ `onBytes` == `Response.bytesWritten` == file length.
- `testShouldAbortStopsTransferAndReportsAborted` — 512 KB body, `shouldAbort`
  flips true after the first `onBytes`: `Response.aborted == true` and the file holds
  exactly `bytesWritten` bytes (no post-abort writes).
- `testResponseCarriesValidators` [F1] — server response includes
  `ETag: "abc"` and `Last-Modified: Tue, 01 Jul 2025 00:00:00 GMT`:
  `Response.etag == "\"abc\""`-style verbatim value and `lastModified` verbatim;
  absent headers → nil.
- `testRangedTwoHundredAbortsEarlyWithRangeIgnored` [F2] — ranged request, server
  answers 200 with a large body: `Response.rangeIgnored == true`,
  `bytesWritten == 0`, `aborted == false` (write-thunk abort, not progress-thunk),
  destination file empty.

Bound-path W2 integration (trip → aborted branch → upgrade) is deliberately NOT
integration-tested: the loopback harness is one-shot and cannot serve the upgraded
phase's ranged follow-ups. Coverage instead: the aborted-branch switch is thin glue
over `classify` + `validatorsAllowResume` + `upgradeToSegmented`, each covered above,
and `shouldAbort` + validator capture are wire-tested here.

[R1][R3] This deliberate gap now covers two of the post-review fixes, so it is worth
restating honestly rather than leaving it as a footnote: the `keepsPrefix` decision
and the throwing `handle.close()` on the upgrade route are both bound-path-only and
both unreachable from the current harness. `keepsPrefix` is composed from statics
that ARE covered (`classify`, `validatorsAllowResume`) and its three-term structure
is small enough to read, but nothing proves the wiring. Closing this needs a
range-capable multi-request loopback server — the same prerequisite the "Stretch"
item below names. Until then the gap is accepted and stated, not papered over.

### Post-review test additions [R1]–[R6]

None of these exist yet; listed so the Test phase owns them explicitly.

- **`testUpgradedStreamEdgeMismatchDiscardsPrefixAndRefetches` [R1]** — needs the
  range-capable loopback server. Assert a bound trip whose captured ETag differs from
  `plan.etag` completes via `upgradeToSegmented(written: 0)` rather than throwing
  `remoteFileChanged`, and that the final file matches the ranged entity byte-for-byte.
  Cheap partial available today: a pure test over the `keepsPrefix` expression's three
  terms (`written == 0`, `written == total`, validator agreement).
- **`testUpgradedTransferIgnoresMirrors` [R2]** — reachable from the StubURLProtocol
  harness once the six behavioral tests land: build the deterministic upgrade shape
  with a mirror in `plan.mirrors` that serves a same-sized but different body, and
  assert every upgraded-phase request went to the primary and the file matches the
  primary's bytes.
- **`testUpgradeInterruptSurfacesCloseFailure` [R3]** — hard to trigger honestly
  (needs a `FileHandle` whose `close()` fails); a `close`-failure injection seam would
  be new production surface. Recorded as known-untested unless the seam is judged
  worth it.
- **`testUpgradedPhaseRetriesEmptyBodiedRangedTwoHundred` [R4]** — the bound twin of
  `testUpgradedPhaseRetriesRangedTwoHundredFlapback`, distinguished by a ZERO-length
  200 body so `range_ignored` stays 0 and the `.reject` arm is the one exercised.
- **[R5]** — comment-only; nothing to test.
- **[R6]** — the deviation is a latency change on a retry path; asserting on backoff
  timing would be a flaky test for no safety gain. Not tested by design.

**Addition: HTTPEngineTests.swift** (integration)
- `testConnectionBudgetBalancesToZeroAfterMidflightUpgrade` — drive the engine
  end-to-end over StubURLProtocol through an upgrade (the probe must report
  no-ranges while ranged GETs 206: serve `supportsRanges: false` during the probe
  phase then flip the config to `supportsRanges: true` once `seenRangeHeaders()`
  shows the probe's `bytes=0-0` — the stub is re-`set` mid-test, which its lock
  allows); after completion assert `engine.connectionBudget.totalConnections == 0`
  and the file is intact. If the flip proves racy against the engine's probe retry,
  downgrade to: budget returns to zero after a normal segmented run plus a direct
  `grantExtraConnections` + release cycle.

**Stretch (only if a range-capable loopback server is added to
BoundHTTPClientTests' harness):** `testBoundSegmentLedgerHoldsPartialBytesOnAbort` —
abort a bound ranged download mid-body and assert the last emitted resume cursor
accounts for the bytes on disk.

---

## Rejected critiques

All ten findings were accepted as findings. Two proposed *remedies* inside them are
rejected:

- **Finding 4's "await `upgrade?.task.value` after cancel" (joined teardown):**
  rejected — Swift `defer` cannot `await`, and once the register re-check closes the
  cancel-vs-register race there is nothing left to join: every probe in flight is
  aborted by the cancellation handler and the prober unwinds within one continuation
  resume, holding only value state.
- **Finding 6's proposed gate `response.curlCode == 0 || response.bytesWritten > 0`:**
  rejected as written — a healthy trip that lands between headers and the first body
  byte has `curlCode == CURLE_ABORTED_BY_CALLBACK` and `bytesWritten == 0`, so that
  gate throws `CancellationError` on an uncancelled task, which `HTTPEngine`'s
  `catch is CancellationError` swallows as its own pause and the task hangs in
  "Downloading". The status-classification switch in the aborted branch achieves
  finding 6's intent without that hazard.
- **Finding 1's fallback "restrict the bound-path upgrade to W == 0":** rejected —
  the prober's ≥ 10 s first attempt guarantees W > 0 on any live link, so this
  option is indistinguishable from deleting the bound upgrade; the two-branch C
  header capture was chosen instead.
  **Partly vindicated by [R1], and it should be said plainly.** The rejection of the
  *unconditional* form still stands for the reason given. But the remedy chosen in
  its place — throw `remoteFileChanged` on a stream-edge mismatch — was itself the
  worst of the three options: it failed downloads that had been completing, and it
  did not self-heal. The shape finding 1 was reaching for turned out to be right, and
  is now what the code does: fall back to `W == 0` **conditionally**, exactly when
  the prefix cannot be proven, and upgrade with the prefix otherwise. The C header
  capture is still needed — it is what tells the two cases apart — so the choice
  between them was a false dichotomy. Recorded so the next reader does not re-derive
  the throw from this bullet.
- **Finding 2's options (b) confirming probe and (c) unranged skip-ahead fallback:**
  not taken — (b) shrinks but cannot close the flap window while adding latency to
  every upgrade; (c) requires a new skip-N-bytes pump mode on both paths (work-
  stealing-adjacent machinery, a stated non-goal). Option (a) bounded retry +
  the C early abort was chosen.
- **Finding 7's premise "the pump path can't trip before a flush":** superseded, not
  disputed — after the [F5] loop-top check the URLSession path CAN produce W == 0
  upgrades too; the [F7] comment covers both paths.

---

## Edit plan

Ordered; each step compiles on its own except where noted. Build gates at the end.

1. **Sources/CurlBridge/include/curl_bridge.h**
   a. `GCBHTTPResult` (:43-49): append `int range_ignored; char etag[256];
      char last_modified[128];` with the doc comments given above.

2. **Sources/CurlBridge/curl_bridge.c**
   a. `struct gcb_http_ctx` (:162-175): append `int range_ignored; char etag[256];
      char last_modified[128];`.
   b. `gcb_http_write_thunk` (:211-241): insert the [F2] ranged-200 early-abort
      branch between the reject/mismatch return and the drain branch, with its
      comment (write-thunk return 0, NEVER via the progress thunk).
   c. `gcb_http_header_thunk`: in the `HTTP/` branch (:271-280) reset
      `ctx->etag[0]`/`ctx->last_modified[0]`; after the `Location:` branch add the
      `ETag:` / `Last-Modified:` parse branches ([F1]).
   d. `gcb_http_range` per-hop result assignment (:492-497 region): copy
      `range_ignored`, `etag`, `last_modified` from ctx into result.

3. **Sources/GoelCore/Engine/BoundHTTPClient.swift**
   a. `Response` (:27-34): add `rangeIgnored: Bool = false`, `etag: String? = nil`,
      `lastModified: String? = nil`.
   b. `TransferContext` (:38): add `let shouldAbort: (@Sendable () -> Bool)?`
      (init param, default nil); `aborted` getter becomes
      `_aborted || (shouldAbort?() ?? false)`.
   c. `downloadRange` (:84): add `shouldAbort: (@Sendable () -> Bool)? = nil`,
      pass into the ctx.
   d. Add the file-private `cString(_:)` tuple helper; populate the three new
      `Response` fields in `performBlocking` (:168-177).

4. **Sources/GoelCore/Engine/ConnectionGovernor.swift**
   a. Append `AdapterGovernors` (W1) verbatim.

5. **Sources/GoelCore/Engine/ConnectionBudget.swift**
   a. Add `extraRoom(host:profile:)` verbatim.

6. **Sources/GoelCore/Engine/HTTPEngine+Transfer.swift**
   a. Add `ExtraGrantCounter` (file scope) and
      `HTTPEngine.grantExtraConnections(host:wanted:)` (in the extension) verbatim.

7. **Sources/GoelCore/Engine/SegmentedTransfer.swift** (order matters)
   a. `TransferPlan` (:1172-1200): add `upgradeProbing` + `requestExtraConnections`;
      add the `UpgradeProbing` struct beside `RequestSettings` (:1203).
   b. File scope beside `StreamerBox` (:1429): add `UpgradeSignal`; nested in
      `SegmentedTransfer`: `private struct UpgradeInterrupt: Error {}`.
   c. New statics near the range math (:731): `upgradeMinBytes`,
      `upgradeMaxConnections`, `shouldAttemptUpgrade`, `upgradedLayout`.
   d. `run()` (:123): call `runSegmented(total: total, ranges: plannedRanges,
      restored: restoredBytes, upgraded: false)`.
   e. `runSegmented` (:140): new signature `(total:ranges:restored:upgraded:)`;
      delete `let ranges = plannedRanges`; `initialBytes` becomes the
      `restored[$0] ?? 0` normalization; create `adapterGovernors` after
      `adapterPool` (:165-166); group (:182) binds `let adapterGovernors` and
      threads it + `upgraded` into both segment pumps.
   f. `downloadSegment` (:212): signature gains `upgraded: Bool`; `.reject` case
      (:268-279) gains the [F2] upgraded ranged-200 retry branch. No other change.
   g. `downloadSegmentBound` (:351-503): signature gains `adapterGovernors:
      AdapterGovernors` and `upgraded: Bool`; W1 acquire pair after :375 with the
      rebalancing catch; all seven releases become reverse-order pairs; `.retry`
      (:439) throttles only `adapterGovernors.throttleDown(adapter.bsdName)`; W3
      tally pump around `downloadRange` (:395-399) + delete both bulk
      `ledger.advance` credits (:422, :473); new [F2] `rangeIgnored` branch between
      the mismatch (:408-415) and curl-error (:419) branches.
   h. `runSingle` (:507-531): spawn prober + defer-cancel; wrap `streamSingle` in
      the `UpgradeInterrupt` catch → `upgradeToSegmented`.
   i. `runSingleBound` (:540-625): spawn prober + defer-cancel; pass
      `shouldAbort: upgrade.map { u in { u.signal.isTripped } }` and replace the
      aborted branch (:587-590) with the [F1]/[F6] classification switch.
   j. `streamSingle` (:629-684): gains `upgrade: UpgradeSignal?`; [F5] loop-top
      trip check after `Task.checkCancellation()` (:642); bind `http` in the
      result guard (:666); compute `entityTied` / `pumpUpgrade` ([F1], with the
      debug log) and thread `pumpUpgrade` to `pumpBody` (:673).
   k. `pumpBody` (:694-725): trailing `upgrade: UpgradeSignal? = nil`; trip check
      at the end of the flush branch (after `removeAll`, :715).
   l. New privates: `spawnUpgradeProber`, `probeMidpointRange` (with the [F4]
      register re-check), `upgradeToSegmented` (with the [F3] guard and the typed
      GoelLog notice).
   m. `init` multi-path stale-cursor guard comment (:79-82): add the [F7] sentence
      about legitimate single-range upgraded cursors.

8. **Sources/GoelCore/Engine/HTTPEngine.swift**
   a. [F10] W3 notice after `let boundAdapters = resolution.adapters` (:504),
      hedged via `shouldAttemptUpgrade`.
   b. `let plan` → `var plan` (:529); attach `requestExtraConnections` +
      `ExtraGrantCounter` after plan construction, before `PlannedTransfer` (:547).
   c. Reservation defer (:558) → `releaseConnections(host: host, count: reserved +
      extraGrants.total)`.

9. **Tests/GoelCoreTests/**
   a. `HTTPEngineTests.swift` — StubURLProtocol additions: `holdUnrangedBodyAt`,
      `unrangedData`, `unrangedETagOverride` Config fields; `releaseUnrangedBody()`,
      `seenRangeHeaders()`, `force200ForMultiByteRangedGETs(_:)` statics, all
      cleared inside `set(_:)`; plus `testConnectionBudgetBalancesToZeroAfter
      MidflightUpgrade` (with its stated downgrade fallback).
   b. New `AdapterGovernorsTests.swift` (4 tests as specified).
   c. New `MidflightUpgradeTests.swift` (gate, layout, deterministic upgrade,
      skip/reject/entity-mismatch/overshoot/flap-back tests as specified).
   d. `ConnectionBudgetTests.swift` — two `extraRoom` tests.
   e. `BoundHTTPClientTests.swift` — four additions (tally, shouldAbort,
      validators, rangeIgnored).

10. **Build gates**: `swift build --target GoelCore` then `swift build
    --build-tests` (Bash timeout 600000). All new Swift code is Foundation +
    NSLock + Task — no Darwin-only APIs; the C additions are `strncasecmp`/
    `snprintf` (both already used in this file, both POSIX); `openStream` already
    carries the Linux `StreamRouter` path and the prober rides it unchanged.

11. **Post-review amendments** (applied after steps 1–10 shipped; all in
    `Sources/GoelCore/Engine/SegmentedTransfer.swift`, no C or test-harness change).
    Steps 7.e, 7.g, 7.i and 7.j above describe the pre-amendment shape and must be
    read together with these:
    a. [R1] 7.i's `.accept` arm: replace the `remoteFileChanged` guard with the
       `keepsPrefix` computation + notice + `written: keepsPrefix ? written : 0`.
    b. [R2] 7.e: `MirrorPool(primary: plan.url, mirrors: upgraded ? [] : plan.mirrors)`.
    c. [R3] 7.j: add a dedicated `catch let interrupt as UpgradeInterrupt` before the
       generic catch, using `try handle.close()`.
    d. [R4] 7.g: add the `upgraded, status == 200, attempt < settings.maxAttempts`
       retry arm inside the `.reject` case, after the release pair and the 401/403
       demote, before the existing `isMirror` arm.
    e. [R5] 7.i: rewrite the comment above `shouldAbort` — no code change.
    f. [R6] no edit; deviation recorded only.

---

## Notes W1

Implemented as specified; both build gates pass. Scope boundaries and the one
ordering choice worth recording:

- `AdapterGovernors` appended to ConnectionGovernor.swift verbatim.
- W2-owned pieces deliberately NOT added here, exactly as the spec's cross-
  references say: no `upgraded: Bool` parameter on either segment pump, no
  `rangeIgnored` branch, and `runSegmented` keeps its current `(total:)`
  signature — the `(total:ranges:restored:upgraded:)` refactor is W2's
  prerequisite (edit-plan step 7.e mixes W1 and W2 items; only the W1 half —
  `adapterGovernors` creation and threading — is done). W2's implementer adds
  the reverse-order release pair inside its new `rangeIgnored` branch per :108.
- `adapterGovernors` is created immediately after the `adapterPool` binding
  (before the ledger label-seeding `if let adapterPool` block), matching the
  ":165-166" anchor literally; both bindings key off `plan.boundAdapters.isEmpty`
  so the group's `if let adapterPool, let adapterGovernors` never splits.
- All seven existing release sites in `downloadSegmentBound` are now
  adapter-then-global pairs; the `.retry` case throttles only
  `adapterGovernors.throttleDown(adapter.bsdName)` (global throttle removed on
  this path only — `downloadSegment` untouched). The acquire pair carries the
  rebalancing `catch` so a cancellation parked on the adapter governor returns
  the already-claimed global slot.
- No tests were added: per the phase split, DESIGN's test section belongs to the
  Test phase; existing tests compile unchanged (`swift build --build-tests`
  clean — the ld dylib-version warnings are pre-existing Homebrew artifacts).

---

## Notes W2

Implemented as specified; both build gates pass with no new warnings. Deviations
(all cosmetic — no behavioral departure from the spec) and scope boundaries:

- **Stream-edge gating in `streamSingle` is wrapped in `if let upgrade`**: the
  DESIGN snippet computes `entityTied` (and emits the debug log on mismatch)
  unconditionally, which would fire the "upgrade disabled" log on every plain
  single-stream download that simply has no validators and no prober. The
  computation + log now run only when a prober exists; `pumpUpgrade` is nil
  either way when `upgrade` is nil, so behavior is identical whenever an
  upgrade is actually possible.
- **`shouldAbort` built with an explicit `if let` instead of
  `upgrade.map { u in { u.signal.isTripped } }`** — same value, but the
  two-step form gives the closure literal the `@Sendable` type context
  directly instead of relying on map-return-type inference.
- `UpgradeInterrupt` lives at the top of the new "Mid-flight upgrade" MARK
  section (still `private struct` nested in `SegmentedTransfer`); the DESIGN
  placed it "nested in SegmentedTransfer" without fixing a position.
- `upgraded:` was appended as the FINAL parameter of both segment pumps
  (after `fileURL:`); the DESIGN did not fix its position.
- `probeMidpointRange`'s doc comment cites ``HTTPEngine/probe`` for the
  openStream+cancelTask pattern instead of a file:line anchor.
- W3-owned pieces deliberately NOT added, per the phase split: no per-attempt
  `ByteTally` pump in `downloadSegmentBound` (its two post-hoc bulk
  `ledger.advance` credits remain until W3 removes them — the new
  `rangeIgnored` branch is tally-neutral either way since C aborts before the
  first body byte), and no [F10] "Aggregation unavailable" notice in
  HTTPEngine plan construction (edit-plan step 8.a is W3's).
- The `rangeIgnored` branch carries the W1 reverse-order release pair
  (adapter then global), as Notes W1 said it must.
- No tests were added (Test phase owns DESIGN's test section); the new
  surface is reachable for it: `shouldAttemptUpgrade` / `upgradedLayout` /
  `probeMidpointRange` are statics, `UpgradeProbing` +
  `requestExtraConnections` are plan fields with defaults, and
  `ExtraGrantCounter` / `ConnectionBudget.extraRoom` /
  `HTTPEngine.grantExtraConnections` are internal.

---

## Notes W3

Implemented as specified; both build gates pass (the ld dylib-version warnings
are the pre-existing Homebrew artifacts noted in Notes W1). No behavioral
deviation from the spec. Details worth recording:

- `downloadSegmentBound` tally pump inserted verbatim from the W3 snippet
  (per-attempt `ByteTally`, 200 ms drain into `ledger.advance(segment:by:)`,
  cancel + join + trailing drain completing before ANY branching). The call
  still omits `shouldAbort` (defaults nil) — zero behavior change there, per
  the W2 cross-reference.
- Both post-hoc bulk credits deleted (curl-error path and success path);
  `written += response.bytesWritten` kept on both for retry-resume offsets and
  the completeness net. The three comments that described the old
  credit-on-commit model ("Ledger is advanced only when we commit `written`",
  "Partial on-disk bytes … committed", "Commit progress only after accept +
  Content-Range validation") were rewritten to state the new invariant —
  tally pump credits the ledger live, Σ onBytes == bytesWritten, only offset
  bookkeeping remains at the old sites — since leaving them would have
  documented the removed behavior.
- Verified in curl_bridge.c (no C changes needed, as the ground-truth section
  claimed): `reject_body`/`range_total_mismatch` returns 0 at the top of the
  write thunk BEFORE `write_cb`, the ranged-200 early abort returns 0 before
  `write_cb`, and error/redirect bodies drain without reaching it — so the
  tally is provably zero on the mismatch, rangeIgnored, and retry/reject
  paths, and no byte can be double-counted or lost.
- [F10] "Aggregation unavailable" notice added after `let boundAdapters`
  exactly as specified (`willReprobe` via `SegmentedTransfer.
  shouldAttemptUpgrade`, `.host`/`.count`/`.flag` typed fields). Cosmetic:
  the comment says "the mid-flight prober" without the "(W2)" work-item tag —
  work-item IDs don't belong in shipped source comments.
- No tests were added (Test phase owns DESIGN's test section). The new
  surface is reachable for it: the tally pump is observable through ledger
  progress ticks and resume cursors, and the notice is log-only.

---

## Notes Fix

A code review of the merged W1+W2+W3 result found five defects, all in
`SegmentedTransfer.swift`, plus one behavior delta that had shipped without being
written down. All six are now reflected in the body above (marked `[R1]`–`[R6]`) and
in decision-log entries 25–30. The five code fixes are applied; [R6] is a deviation
accepted as-is. All five fixes were verified in place in
`Sources/GoelCore/Engine/SegmentedTransfer.swift`; none of them required a change to
the C bridge, `BoundHTTPClient`, `ConnectionBudget`, `ConnectionGovernor` or
`HTTPEngine`, and [R1]'s root cause (`Accept-Encoding: identity`, curl_bridge.c:413)
was confirmed to be pre-existing rather than something W2 introduced.

What was found, in the order the defects bite:

- **[R1] The bound-path stream-edge guard failed downloads it should have degraded.**
  The most serious of the five, and the one whose blast radius reached beyond the new
  feature: a mismatch threw `DownloadError.remoteFileChanged` and permanently killed
  a transfer that had been completing fine before the upgrade branch existed, on any
  origin that varies the ETag by content-coding — which is the *normal* case here,
  since the probe rides URLSession/gzip and every bound request rides
  curl/`identity`. It did not self-heal, and it swept in the separately-reported ETag
  truncation defect (long S3-multipart validators overflowing `char etag[256]`) as a
  second trigger for the same permanent failure. Now a mismatch discards the
  unprovable prefix and refetches over ranges; the truncation report degrades with it.
- **[R2] Upgraded transfers could splice a mirror's entity onto a primary prefix.**
  Silent corruption reported as `.completed`. Mirrors are now suppressed for upgraded
  transfers.
- **[R3] A swallowed `close(2)` error could leave an invisible hole in the kept
  prefix.** The upgrade is the only error path whose on-disk bytes survive, so it is
  the only one that cannot use `try?`. Also silent corruption, narrower trigger
  (NFS/SMB-class late write errors).
- **[R4] An empty-bodied ranged 200 killed the whole upgraded download on the bound
  path.** Availability, not correctness. The URLSession twin never had the bug.
- **[R5] A comment stated an invariant the code does not have.** No behavior change;
  recorded as a documentation correction because the wrong invariant argued against
  the write-thunk abort path being safe, and that path is load-bearing.
- **[R6] Bound mirror flap-back retry latency changed** from immediate to one
  backoff interval, because body-carrying flaps now route through the new
  `rangeIgnored` branch. Verified against `git show
  main:Sources/GoelCore/Engine/SegmentedTransfer.swift`; DESIGN's "as today" claim
  was simply wrong. Accepted, not reverted.

Verification state, as of this amendment:

- `swift build --build-tests` — clean (the ld dylib-version warnings remain the
  pre-existing Homebrew artifacts noted in Notes W1).
- `swift test` — **986 tests, 4 skipped, 0 failures** (979 before the behavioral
  tests below were added; 986 = exactly those 7).

**Coverage, stated precisely.** The behavioral tests mandated by the test section now
exist and drive real end-to-end upgrades, but the coverage is not uniform — read the
MISSING list below before treating a green suite as proof of any particular path:

- `AdapterGovernorsTests.swift` — the four W1 tests DESIGN specifies, plus one
  extra (`testDuplicateAdapterEntriesShareOneGovernor`).
- `MidflightUpgradeTests.swift` — 20 tests. 13 pure: the gate
  (`shouldAttemptUpgrade`), seven `upgradedLayout` cases, `UpgradeSignal` stickiness,
  `ExtraGrantCounter`, and two `grantExtraConnections` cases. Plus the 7 behavioral
  tests in `MidflightUpgradeBehaviourTests`, detailed below.
- `ConnectionBudgetTests.swift` — the two `extraRoom` tests plus one extra.
- `BoundHTTPClientTests.swift` — all four specified additions (tally, `shouldAbort`,
  validator capture, `rangeIgnored`).
- The `StubURLProtocol` harness additions the behavioral tests depend on:
  `Config.holdUnrangedBodyAt`, `Config.unrangedData`, `Config.unrangedETagOverride`,
  `releaseUnrangedBody()`, `seenRangeHeaders()`, `force200ForMultiByteRangedGETs(_:)`,
  all cleared inside `set(_:)`. Held deliveries dispatch to their own concurrent
  queue: URLSession serves custom `URLProtocol` requests from a **shared** loader
  thread, so parking the unranged body inline wedges the range probe behind it and
  no upgrade can ever fire. Unheld deliveries keep the original inline path, so
  pre-existing tests are behaviorally byte-identical.

**Now covered** — `MidflightUpgradeBehaviourTests` (7 tests) drives real end-to-end
upgrades through the URLSession path:

- All six behavioral tests the test section mandates, with two deliberate
  strengthenings recorded below.
- `testConnectionBudgetBalancesToZeroAfterMidflightUpgrade`, taking DESIGN's own
  stated downgrade path but kept stronger than the suggested "normal segmented run +
  direct grant/release": it drives a real mid-flight upgrade whose
  `requestExtraConnections` **is** the engine's `grantExtraConnections`, recording
  into a real `ExtraGrantCounter` and applying the identical arithmetic the engine's
  `defer` uses.

Two tests deviate from the sequencing this document specified, both for determinism:

- `testUpgradeOvershootFailsInsteadOfCompleting` — DESIGN says "after probe +
  release, the first flush past the hold sees the trip". Unreachable with a fast
  prober: at `initialDelay: 0.05` the trip fires long before the stream reaches
  10 MiB, so the pump would interrupt at `written < total` and take the ordinary
  upgrade path instead of the overshoot guard. Made causal instead — start with
  `supportsRanges: false` (probes get 200, no trip), wait until the destination file
  on disk is ≥ 10 MiB (the file *is* the flush ledger), flip the stub to
  `supportsRanges: true`, wait for a post-flip midpoint probe, then release. The
  assertion pins the reported figure to the probed total rather than the full body,
  proving it is `upgradeToSegmented`'s guard and not `runSingle`'s end-of-stream net.
- `testUpgradeRejectedWhenProbeValidatorsChanged` — DESIGN's version (stub serves v2,
  plan holds v1) fails *both* validator edges at once and cannot distinguish which
  guard refused. The stream is given `unrangedETagOverride: "\"v1\""` so the stream
  edge passes and only the probe edge can refuse, making it the exact mirror of
  `testUpgradeDisabledWhenStreamEntityDiffers`.

Still **MISSING**:

- `HTTPEngine` never sets `upgradeProbing` when building its `TransferPlan`, so an
  engine-driven upgrade cannot fire before the production 10 s initial delay. The
  budget test therefore covers the grant arithmetic but **not the wiring of the
  `defer` inside `HTTPEngine.start`**. Closing that needs a probing seam on
  `HTTPEngine`, deliberately not added.
- Regression tests for [R1] and [R4]: both live on the bound path, which no test can
  drive through an upgrade — the loopback harness is one-shot, the same limitation
  the test section already records for bound-path W2 integration.
- [R3]'s *failure* mode: it needs a `FileHandle` whose `close()` fails, which is not
  injectable today. Its success path is now exercised by the behavioral tests, but
  the close-failure branch the fix exists for is structurally right and empirically
  unproven.

[R2] is covered — the upgraded segmented phase the behavioral tests reach is exactly
where mirror suppression applies. [R5] is comment-only and has nothing to test.
