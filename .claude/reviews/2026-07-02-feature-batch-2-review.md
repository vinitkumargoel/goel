# Review — Feature Batch 2 (2026-07-02)

**Scope**: The 19-feature batch (waves 1–7): Finder/Dock progress, duplicate
surfacing, batch patterns, checksum discovery, history archive, scheduled
starts, remote QR/Bonjour/SSE/streaming, browser extension + native messaging,
multi-mirror + metalink, AppleScript, FTP/FTPS engine (libcurl shim), yt-dlp,
link grabber, notarization pipeline, Sparkle.
**Method**: Two parallel specialist reviews (security surfaces; correctness/
concurrency), findings verified and fixed in place.
**Validation**: `swift build` clean, 165 tests passing (baseline 134),
`Scripts/build_app.sh` produces a valid bundle (Sparkle framework + rpath,
sdef loads via `sdef(1)`, Info.plist lints), native-messaging host smoke-tested
over real stdio frames.

## Findings & Resolutions

### HIGH — fixed
1. **FTP engine could send Keychain site logins over cleartext FTP**
   (`FTPEngine`, `curl_bridge.c`). Stored logins carry an "HTTPS-only" promise
   in the HTTP engine, but the FTP fallback used `CURLUSESSL_TRY` — a server
   declining AUTH TLS received the password in cleartext `USER`/`PASS`.
   → `gcb_download`/`gcb_remote_size` gained a `require_tls` mode
   (`CURLUSESSL_ALL`); Keychain-sourced credentials now REQUIRE TLS (transfer
   fails rather than downgrades). Inline `ftp://user:pass@host` userinfo (the
   user's explicit per-URL choice) stays opportunistic.
2. **FTP pause→resume / remove race: two curl threads writing one file**
   (`FTPEngine`). `abort()` is only observed at the next libcurl progress
   tick (~1 s; longer when stalled), so a quick resume opened a second
   `FileHandle` + curl thread against the same path, and remove-with-delete
   could unlink the file while the old thread was still writing (then corrupt
   a re-added download at the same path).
   → Transfers are serialized per task: `startJob` chains on the previous
   job's completion; `remove` awaits the job before deleting and re-checks
   `isSavePathContained` at delete time (matching the HTTP engine);
   `run()` no longer touches `jobs[id]` (a late failure path could clobber a
   successor's handle).

### MEDIUM — fixed
3. **Wrapper script interpolated the binary path unescaped into `/bin/sh`**
   (`BrowserIntegrationService.writeWrapperScript`). A bundle path containing
   `$(…)`/backticks/`"` would execute as shell every time a browser spawned
   the native-messaging host. → Single-quoted with `'\''` escaping.
4. **Stale checksum/mirrors silently applied to a different URL**
   (`AddDownloadSheet`). Back → paste a different link → Continue kept the
   previous link's checksum (spurious mismatch failure) and mirrors.
   → Both fields reset when a new resolution starts.
5. **Remote server idle-timeout vs. receive race double-decremented the
   connection counter** (`RemoteControlServer`), letting a client that times
   its first byte near the 10 s mark erode the 32-connection cap (pre-auth).
   → Per-connection identifier set makes slot release exactly-once.

### Reviewed clean (verified, no changes)
- `/api/events` + `/stream`: auth-first, constant-time token, caps enforced,
  Range parsing clamped, no header injection; torrent file paths can't
  traverse (libtorrent sanitizes leaf names).
- Native messaging: bounded wire frames, spool drain cap, scheme allowlist,
  drain trigger is content-free (spool = local-only trust boundary).
- Mirror pool: Authorization stripped for cross-host mirrors, Content-Range
  total verified before trusting mirror bytes, governor acquire/release
  balanced on every new exit path, retry attempts bounded.
- Metalink/link-grabber/yt-dlp: http(s)-only after resolution, size caps
  (5 MB / 8 MB), result caps (50 / 500), names sanitized, argv-array exec.
- Scheduled-start loop: no double-loop, no lost schedules (self-healing arm).
- GRDB history table fully parameterized; archiving idempotent.
- `build_app.sh` quoting; `curl_bridge.c` Unmanaged lifetimes; no TLS
  verification disabled anywhere.

## Validation

| Check | Result |
|---|---|
| swift build | Pass |
| swift test (165 tests, 4 env-skipped) | Pass |
| Scripts/build_app.sh (packaged .app) | Pass |
| Info.plist lint (generated) | Pass |
| sdef loads from packaged bundle | Pass |
| Native-messaging host stdio smoke test | Pass (valid URL spooled; `file://` rejected) |
