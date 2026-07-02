# 360° Code Review — Feature Batch (2026-07-02)

**Scope**: All uncommitted changes — 21 features across engines, scheduler, persistence,
app layer, C shim, and packaging (~28 modified + 14 new files).
**Method**: Three parallel specialist reviews (core correctness/concurrency,
security surfaces, app/SwiftUI layer), findings verified and fixed in-place.
**Decision**: All CRITICAL/HIGH findings fixed and covered by regression tests.
Validation: `swift build` clean, 134 tests passing, generated Info.plist lints OK.

## Findings & Resolutions

### CRITICAL — fixed
1. **Backup import silently clobbered all settings** (`DownloadManager.importEnvelope`).
   A hostile "backup" JSON could enable the remote server (LAN + attacker token),
   register an exfiltration post-download script, and inject RSS feeds.
   → `sanitizedImportedSettings` now forces every code-execution / listener /
   auto-fetch field back to the current value on import. Regression test added.

### HIGH — fixed
2. **`.torrent` suffix bypassed the scheme allowlist** (`DownloadSource.parse`).
   `file:///…/x.torrent` (and any scheme) was accepted before the scheme check,
   reachable from the remote API, RSS items, and the URL scheme.
   → Scheme check now precedes suffix routing (http/https only). Local `.torrent`
   opens construct `.torrentFile` directly from the user's file-open action.
3. **Basic auth sent over plaintext HTTP** (`HTTPEngine+Requests`, transfer path).
   → `Authorization` attaches only when `scheme == https` (both probe and segments).
4. **Authorization header could follow a cross-host redirect** (no session delegate).
   → `RedirectSanitizer` session delegate strips the header when a redirect changes
   host or downgrades to HTTP.
5. **Update checker opened unvalidated URLs from a tamperable feed** (`UpdateChecker`).
   → Feed must be HTTPS; the release page must be HTTPS before `NSWorkspace.open`.
6. **Auto-shutdown fired on manual "Pause All"** when any old completed task sat in
   the list (`AppViewModel.checkQueueDrained`).
   → Requires a transition *into* `.completed` on the same tick (checked against
   previous statuses, ordered before the notification diff overwrites them).
7. **Cold-launch external adds were dropped** (magnet/.torrent/link opens arriving
   before the view model subscribed).
   → `ExternalAdd` buffers payloads until `drainPending` replays them.
8. **Automation pause loops could adopt user-paused tasks** and auto-resume them
   later (window close + network policy loops suspend inside `pause()`).
   → Per-iteration re-validation: only tasks still in a downloading phase are
   paused and recorded.
9. **RSS `startPaused` raced the scheduler's optimistic promotion** (add-then-pause
   could leave the engine downloading a held item; same latent race in the
   watch-folder confirm path).
   → `add(source:startPaused:)` creates the task directly `.paused` and never
   schedules; both call sites migrated. Regression test added.

### MEDIUM — fixed
10. **Loopback-only remote binding specified the port twice** (requiredLocalEndpoint
    + `on:` port), likely failing with EINVAL behind `try?` — silently pushing users
    toward LAN mode. → Port is now specified exactly once per mode.
11. **Remote server DoS**: unbounded idle connections, no receive timeout.
    → 32-connection cap + 10 s idle timeout.
12. **Missing security headers** on the control page. → CSP (`default-src 'none'`
    with same-origin connect), `X-Content-Type-Options`, `X-Frame-Options`.
13. **Web-triggerable `goeldownloader://` adds queued silently.**
    → Scheme adds now validate the inner target (http/https/magnet) and surface as
    the confirmation banner; explicit user actions (Services, drop basket, file
    opens) still queue directly.
14. **Stats lost re-transferred bytes** after a validator-rejected resume restarted
    below the previous count. → Per-task stats marks re-base on regression.
15. **Window-close profile restore clobbered a manual profile change** made while
    the window was open. → Restore only when the schedule's own profile is still active.
16. **Idle 1 Hz re-render churn** from the speed sampler. → Sampling skips once the
    app is idle and the history has flattened.

### LOW — fixed
17. Non-constant-time token comparison → constant-time byte compare (test added).
18. Transient window-gate gap after settings changes → gate now set synchronously.

### Accepted (documented, not fixed)
- `rssSeenKeys` grows unbounded per process (double-guarded by queue dedup; resets on relaunch).
- Interpreter blocklist for scanner/script paths is literal-path-based (defense-in-depth
  only; the settings-import hole that made it exploitable is closed).
- Remote token also rides in the URL query (needed for the page bootstrap; UUID-strength).

## Validation

| Check | Result |
|---|---|
| swift build | Pass |
| swift test (134 tests) | Pass |
| Info.plist lint | Pass |
