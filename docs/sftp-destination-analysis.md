# SFTP Download Destination — failure analysis, guardrails, and feature gate

> **Status: IMPLEMENTED (relay mode), behind `sftpDestinationEnabled` — default off.**
>
> Ships 1 and 2 are built: `RemoteDestination`, `RemoteUploadCoordinator`, the atomic
> upload path in the C shim, the preflight, the staging budget, and the UI. Ship 3
> (streaming straight to the server without staging locally, guardrail G21) is **not**
> built. The companion UI study is [`../visual.html`](../visual.html).
>
> Everything below is written against the **real, current** code — every `file:line`
> citation was read from the repository at `main` and describes how the code behaves
> *today*, not how it would behave after the feature lands. The guardrails and the
> feature gate are **specifications to build against**, not descriptions of existing
> behaviour.

---

## 0. Locked scope

Decided in review. These supersede anything below that reads more broadly.

| Decision | Choice | Consequence |
|---|---|---|
| **Download kinds in v1** | Everything **except torrents** — HTTP/HTTPS, FTP, HLS, SFTP→SFTP | Removes libtorrent's opaque storage, the multi-thousand-file session storm (#20), and the seeding-vs-cleanup question (G28) from v1 entirely |
| **Delivery modes** | Both relay and streaming, eventually | Mode A survives, but lands last |
| **Entry points** | Right-click-a-finished-download **and** the Add-sheet picker | |
| **Sequencing** | **Three ships** — right-click → add-time relay → streaming | Each independently useful; each de-risks the next |
| **Headless surfaces** | **None.** Interactive macOS UI only | Watch folders, RSS, remote API, AppleScript, native messaging and `GoelDaemon` all refuse a remote destination in v1 |
| **Torrent seeding policy** | Upload and stop seeding | **Recorded for later — moot in v1**, since torrents are excluded |

### 0.1 The three ships

**Ship 1 — "Send to server" on a completed download.**
No mode concept, no picker, no scheduler interaction. Proves the upload stage against
real servers: preflight, `.part` + rename, conflict handling, cancel ordering, and the
reconcile fix. **Needs no staging directory at all** — the file already sits in its
normal download folder — so the staging budget (G19) and dedup (G12) do not apply yet.

**Ship 2 — Add-sheet destination picker, relay mode.**
Staging arrives, and with it queue-time preflight, two-phase progress, the staging
budget, and destination-aware dedup.

**Ship 3 — Streaming (Mode A).**
Eligible: single-connection HTTP, FTP, SFTP→SFTP. **HLS is relay-only permanently** —
it concatenates segments and remuxes through AVFoundation (`HLSEngine.swift:14-20,
189-222`), so there is no interceptable stream regardless of scope.

### 0.2 Remaining decisions — resolved

**Ship 1 keeps the local copy by default.** "Send to server" is a *copy* operation, the
way a Finder drag or `scp` is. Destructive-by-default is the wrong posture for the first
release of an unproven upload pipeline: if verification has a bug, delete-by-default
loses data permanently. An explicit **"Remove local copy after upload"** checkbox is
offered and remembered between invocations, so the disk-pressure case costs one click
once.

When that box is ticked, deletion is gated on a strict success sequence — **any step
failing leaves the local file untouched**:

```
upload to <name>.part  →  stat remote size == local size  →  rename .part → <name>
                       →  re-stat to confirm the rename landed  →  delete local
```

G15 ships in Ship 1 regardless of this choice. Ship 2 needs it unconditionally, and the
failure mode — a task silently vanishing five seconds after succeeding — is bad enough
that it should never be reachable.

**Multi-file payloads preserve their directory structure.** Flattening collides
(`00001.ts` appears in every HLS variant directory) and is lossy in a way that cannot be
undone. `uploadFolder` already recurses and `mkdir`s shallowest-first
(`AppViewModel+SFTPTransfers.swift:257-307`), so preserving costs almost nothing.
Consequence for **G1**: the path validator must run on **every component of every nested
path**, not just the chosen top-level directory — a deep tree is precisely where a
hostile or malformed component would otherwise slip through.

**Servers get a default upload folder, always overridable per download.** Added as a new
optional `defaultUploadPath: String?` on `SFTPConnection`, resolved as:

```
defaultUploadPath  ??  initialPath  ??  "."
```

Deliberately *not* reusing `initialPath` — that field means "where the browser opens"
(`Model/SFTPConnection.swift:14`), which is a genuinely different intent. Someone may
browse from `/` while wanting downloads in `/srv/media`, and overloading one field to
mean both would make each setting silently move the other. Optional, so existing
persisted connections decode unchanged.

---

## 1. What the feature does, and its entry points

### 1.1 User-facing definition

**SFTP download destination** — when adding a download, the user may choose a saved
SFTP server (and a directory on it) instead of a local folder. The payload ends up on
that server.

Two delivery modes, per [`visual.html`](../visual.html) §4:

| Mode | Behaviour | Applies to |
|---|---|---|
| **Relay** (default) | Download to a local staging folder at full speed → verify → upload → delete local copy. | All download kinds |
| **Stream** (opt-in) | Bytes pass through a bounded memory buffer straight to the server; nothing touches local disk. | Single-connection HTTP, FTP, SFTP→SFTP only |

### 1.2 Entry points that would need the gate

Every path below can create a download task today. Each one must either carry a
remote destination, inherit a default, or explicitly refuse — and each must check the
feature flag. This inventory is the authoritative "gate at every entry point" list.

| # | Entry point | File:line | Passes `saveDirectory` | UI present? |
|---|---|---|---|---|
| 1 | Add-download sheet (single) | `Views/AddDownloadSheet.swift:559` (`vm.confirm`) | explicit | yes |
| 2 | Add-download sheet (batch / no-preview) | `Views/AddDownloadSheet.swift:195, 507` | explicit | yes |
| 3 | Link Grabber | `Views/LinkGrabberSheet.swift:192` | `nil` | yes |
| 4 | Drop Basket / root drop | `Views/RootView.swift:164` | `nil` | yes |
| 5 | Services menu / URL scheme / file open | `GoelDownloaderApp.swift:246, 252, 271, 290` | `nil` | partial |
| 6 | Clipboard monitor | `ClipboardMonitor.swift` → `ExternalAddRouter` | `nil` | prompt only |
| 7 | Browser extension → native messaging | `NativeMessagingHost.swift:42, 101` (`BrowserSpool.enqueue`) | `nil` | **no** |
| 8 | External add router | `ExternalAddRouter.swift:69, 123` (`InboundAdd.classify`) | `nil` | conditional |
| 9 | AppleScript | `ScriptingSupport.swift` | `nil` | **no** |
| 10 | Watch folders | `WatchFolderMonitor.swift` → automation | `nil` | **no** |
| 11 | RSS feeds | `Scheduler/RSSFeed.swift` → `DownloadManager+Automation.swift:93` | `nil` | **no** |
| 12 | Remote-control HTTP API | `Remote/RemoteRouter.swift:136-148` (`POST /api/add`) | **client-supplied** | **no** |
| 13 | SFTP browser → enqueue download | `AppViewModel+SFTP.swift:75` | `nil` | yes |
| 14 | Torrent file add | `AppViewModel.swift:813` | default | varies |
| 15 | Import (`AppExport`) | `Persistence/AppExport.swift` | from blob | no |

**Choke point:** all of these funnel into `DownloadManager.add(source:saveDirectory:priority:…)`
(`Scheduler/DownloadManager.swift:429-441`). That is the single best place for the
core-side gate — but it is **not sufficient alone**, because the UI must also not
*offer* the option, and the upload stage runs later, after the download completes.

**Six entry points run with no user present** (7, 9, 10, 11, 12, 15). They cannot show a
destination picker, a host-key trust prompt, or a conflict dialog.

**Per §0, all six refuse a remote destination in v1** — as does `GoelDaemon`. This is the
single largest risk reduction available: it retires the headless trust-on-first-use
problem (G8) outright and lets the remote-API refusal (G5) be absolute rather than
conditional. The refusal must still be *written* — a path that merely never receives a
destination today becomes a vulnerability the moment someone widens scope later.

Ship 1 adds a sixteenth entry point that is **not** in the table above, because it does
not create a task: **right-click → Send to server** on an already-completed download. It
is the only entry point in Ship 1.

---

## 2. Data flow and dependencies

### 2.1 Proposed flow (relay mode)

```
add(source:, remoteDestination:)          ← gate check #1 (core)
  └─ task.saveDirectory = <staging dir>
     task.remoteDestination = RemoteDestination?
        │
        ├─ download phase   (unchanged: HTTPEngine / FTP / SFTP / HLS / Torrent)
        │     └─ writes to task.savePath, local disk
        │
        ├─ completion pipeline  (DownloadManager+SideEffects.swift:147-218)
        │     ├─ checksum verify      ChecksumVerifier.swift:80-106
        │     ├─ antivirus scan       AntivirusScanner.swift:34-50
        │     └─ extract / script     DownloadManager+SideEffects.swift:195-242
        │
        └─ NEW: upload stage          ← gate check #2 (core)
              ├─ preflight (reachable? space? conflict?)
              ├─ SFTPClient.upload → gsb_upload → libssh2
              ├─ verify remote size
              ├─ rename .part → final
              └─ delete local staged copy
```

### 2.2 What it depends on

| Dependency | File | Relevant constraint |
|---|---|---|
| SFTP client | `Engine/SFTPClient.swift:121-161` | `upload` reads from a local `FileHandle`; pull-callback underneath |
| C shim | `SSHBridge/ssh_bridge.c:317-371` | `LIBSSH2_FXF_TRUNC`, no seek, no append → **uploads cannot resume** |
| Session model | `Engine/SFTPClient.swift:47-50, 195-230` | One TCP+SSH+auth handshake **per operation**, on a dedicated `Thread`; no pooling |
| Saved servers | `Model/SFTPConnection.swift:6-35` | No password field; `credentialKey = "user@host:port"` |
| Credentials | `Persistence/SFTPConnectionStore.swift:43-101` | Keychain, keyed by `credentialKey` |
| Host keys | `Ports/HostKeyStore.swift:12-49` | TOFU pinning, `UserDefaults`-backed |
| Remote paths | `Model/SFTPConnection.swift:58-88` | `SFTPBrowserPaths.join` is **raw string concat, no traversal guard** |
| Settings | `Scheduler/AppSettings.swift` | Plain `Codable` struct; flags default OFF by convention |

---

## 3. Edge cases

Legend — **Sev:** 🔴 critical · 🟠 high · 🟡 medium · ⚪ low.

### 3.1 Input validation and remote paths

| # | Case | Where it fails | Symptom | Sev | Stop mechanism | Guardrail to add |
|---|---|---|---|---|---|---|
| 1 | Remote dir contains `../` | `SFTPBrowserPaths.join` (`SFTPConnection.swift:60-64`) does raw concat with no guard | File written outside intended dir | 🔴 | Reject at validation, before any session | **G1** `RemotePathSafety.isSafeDirectory` — reject `..`, empty components, control chars, non-absolute unless `.` |
| 2 | Filename legal on macOS, illegal on server | `gsb_upload` open fails, or server mangles it | Upload fails late, after full download | 🟡 | Fail the upload stage; keep local | **G2** Re-sanitise the name against a POSIX-conservative charset before upload |
| 3 | Filename contains newline / control chars | Protocol confusion in the SFTP path string | Undefined; possible wrong-path write | 🟠 | Reject at validation | **G1** (same validator) |
| 4 | Remote path exceeds server `PATH_MAX` | libssh2 open fails | Late failure | ⚪ | Fail upload | **G3** Length cap (dir + name ≤ 4096 bytes, name ≤ 255) |
| 5 | Destination "directory" is actually a file | `gsb_upload` creates/truncates a path under it | Confusing error, or truncating a real file | 🟠 | Preflight `stat` | **G4** Preflight must confirm the target is a directory |
| 6 | Destination is a **symlink** to somewhere else (e.g. `/etc`) | libssh2 follows it | Writes outside the intended tree | 🔴 | Preflight | **G4** + resolve and re-check, or refuse symlinked destinations |
| 7 | Destination doesn't exist | Open fails | Late failure | 🟡 | Preflight | **G4**; offer create-dir explicitly, never auto-`mkdir -p` silently |
| 8 | No write permission | Open fails | Late failure after full download | 🟡 | Preflight write probe | **G4** |
| 9 | Unicode NFD (macOS) vs NFC (Linux) | Name differs from what the browser listed | Duplicate-looking files; conflict check misses | ⚪ | — | **G2** normalise to NFC before compare and upload |
| 10 | Empty / whitespace remote dir | Falls through to `.` (login home) | File lands in `$HOME` unexpectedly | 🟡 | Validation | **G1** reject empty; require explicit `.` for home |

### 3.2 Authentication and authorisation

| # | Case | Where it fails | Symptom | Sev | Stop mechanism | Guardrail |
|---|---|---|---|---|---|---|
| 11 | **Remote-control API sets an SFTP destination** | `RemoteRouter.swift:136-148` accepts a client `folder`; the local analogue is contained by `remoteSaveDirectory` (`:591-599`) — a remote destination has **no equivalent containment** | Authenticated portal client writes to `~/.ssh/authorized_keys` or `/etc/cron.d` **on the SFTP server** → RCE on another machine | 🔴 | Refuse at the router | **G5** The remote API **must never** accept or select a remote destination. Server-side allowlist only; strip the field from `/api/add` |
| 12 | Password changed / rejected | `SFTPClient` auth | Upload fails; download safe locally | 🟡 | Fail stage, keep local | **G6** Retry budget + surfaced "update password" action |
| 13 | ssh-agent absent or holds no identity | auth | Same | 🟡 | Same | **G6** |
| 14 | Keychain locked / access denied | `SFTPConnectionStore.password(...)` | Silent nil password → auth failure | 🟡 | Distinguish "no password" from "wrong password" | **G6** classify the error |
| 15 | **Host key mismatch (MITM)** | `HostKeyStore` compare in shim | Upload blocked | 🔴 | Hard stop | **G7** Never auto-trust. No "continue anyway". Re-trust only from server settings |
| 16 | **Host key not yet pinned, upload runs headless** | TOFU learns on first connect (`SFTPClient.swift:234-242`) | A background upload (RSS/watch folder) silently pins whatever key answers — TOFU with no human | 🟠 | Require prior pin | **G8** Refuse an unattended upload to a server with no pinned host key. Pinning must happen in an interactive session |
| 17 | Server deleted from settings while task pending | `connectionID` dangles | Upload can never run | 🟡 | Detect on resolve | **G9** Fail the stage with a clear message; keep local copy; offer re-target |
| 18 | Server host/user/port edited → `credentialKey` moves | `SFTPConnectionStore.save` migrates the secret (`:63-76`), but a pending task's pinned expectations change | Auth or host-key failure | 🟡 | Same | **G9** |

### 3.3 Concurrency and races

| # | Case | Where it fails | Symptom | Sev | Stop mechanism | Guardrail |
|---|---|---|---|---|---|---|
| 19 | **N tasks complete at once → N SSH sessions** | One dedicated `Thread` + full handshake per op (`SFTPClient.swift:47-50, 195-230`); no pooling | Thread and FD exhaustion; server `MaxStartups` throttling or ban | 🟠 | Global semaphore | **G10** Cap concurrent uploads (suggest 2/server, 4 global); queue the rest |
| 20 | Multi-file torrent with thousands of files | Same, multiplied | Session storm; upload takes longer than the download | 🟠 | Same + batching | **G10** + reuse the existing `maxParallelUploads = 4` window (`AppViewModel+SFTPTransfers.swift:252`) |
| 21 | Two tasks target the same remote path | No locking | Interleaved truncating writes; corrupt file | 🟠 | In-process path lock | **G11** Serialise by `(connectionID, remotePath)`; `.part` names must be unique per task |
| 22 | **Same URL added twice, different destinations** | `dedupIndex[source.dedupKey]` returns the existing task (`DownloadManager.swift:442-445`), **silently discarding the new destination** | User asks for a server copy, gets nothing; no error | 🟠 | Explicit handling | **G12** Treat destination as part of identity, or surface "already queued with a different destination" |
| 23 | Task removed while uploading | `remove(_:deleteData:)` deletes `savePath` in each engine | Upload reads a deleted file; possible truncated remote file | 🟠 | Cancel first | **G13** Removal must cancel the upload and await teardown before deleting local bytes |
| 24 | Task renamed while uploading | `moveItem` under `saveDirectory` (`DownloadManager.swift:914-935`) | Upload source vanishes mid-read | 🟡 | Block rename | **G13** Refuse rename during upload |
| 25 | **Flag turned OFF while uploads in flight** | — | Undefined | 🟠 | Drain, don't abandon | **G14** See §5.4 |
| 26 | Upload stage races the 5s reconcile sweep | `DownloadManager+FileReconcile.swift:60-66` | See #31 | 🔴 | — | **G15** |

### 3.4 Partial failure and interruption

| # | Case | Where it fails | Symptom | Sev | Stop mechanism | Guardrail |
|---|---|---|---|---|---|---|
| 27 | Network drops mid-upload | libssh2 write | Orphan `.part` on server | 🟠 | Retry with cleanup | **G16** `.part` + `rename`; on retry, remove the stale `.part` first |
| 28 | Server disk fills mid-upload | libssh2 write | Orphan `.part` consuming space on an already-full disk | 🟠 | Explicit cleanup action | **G16** + surface the orphan's size |
| 29 | **App quit mid-upload** | `AppViewModel.swift:466-475` — the code comments that AppKit **does not await fire-and-forget Tasks on `willTerminate`**, so `manager.shutdown()` is deliberately *not* wired | Upload dies; `.part` orphaned; task state possibly unpersisted | 🟠 | Persist intent before starting | **G17** Persist `.uploading` state *before* the first byte; reconcile orphans at launch |
| 30 | Crash mid-upload | same | same | 🟠 | same | **G17** |
| 31 | **Reconcile sweep deletes the completed task** | `completedPayloadIsMissing` returns true when `saveDirectory` exists but `savePath` does not (`DownloadManager+FileReconcile.swift:60-66`) — exactly the post-cleanup state of a remote task | Task **vanishes from the list within 5 seconds** of succeeding | 🔴 | Teach the sweep | **G15** Skip tasks with a `remoteDestination` whose upload completed; never prune on local absence alone |
| 32 | Sleep/wake mid-upload | `PowerManager.swift` | Session dies on wake | 🟡 | Detect + retry | **G16** + power assertion while uploading |
| 33 | SSH idle timeout (`ClientAliveInterval`) | No keepalive configured anywhere in the shim | Long uploads killed | 🟡 | Keepalive | **G18** Enable libssh2 keepalive on the session |
| 34 | Local staged file deleted by user mid-upload | `FileHandle` read | `SFTPClient.upload` handles a read error via `ReadErrorBox` and aborts (`SFTPClient.swift:133-159`) — good | Upload fails cleanly | ⚪ | already handled | — |
| 35 | Rename-into-place fails after a full write | `gsb_rename` | Bytes uploaded but file still named `.part` | 🟡 | Retry rename only | **G16** Separate the rename failure from the upload failure; do not re-send |

### 3.5 Resource limits

| # | Case | Where it fails | Symptom | Sev | Stop mechanism | Guardrail |
|---|---|---|---|---|---|---|
| 36 | Local staging disk full | `HTTPEngine+Disk.swift:22-46` preflight is **local-volume specific** and already exists | Download fails | 🟡 | existing preflight | **G19** Extend to account for staging |
| 37 | **Cumulative staging across many pending uploads** | No such accounting exists | Boot disk fills from N files awaiting a down server | 🟠 | Running total | **G19** Track total staged bytes; pause new remote-destination downloads above a cap |
| 38 | Segmented HTTP **preallocates full size immediately** (`SegmentedTransfer.swift:114, 766-773`) | — | A 154 GB download claims 154 GB at second one, not gradually | 🟠 | Hard preflight | **G19** Preflight is a gate, not a warning |
| 39 | Remote disk full at preflight | `libssh2_sftp_statvfs` exists but is **not wrapped** in the shim | Cannot preflight remote space at all today | 🟡 | Add wrapper | **G20** Add `gsb_statvfs`; treat absence as "unknown", warn but allow |
| 40 | Mode A ring buffer unbounded | — | Memory blowup | 🟠 | Bounded buffer | **G21** Fixed-size buffer (≈8 MB) with real backpressure |
| 41 | Mode A producer/consumer deadlock | Async Swift producer ↔ blocking C consumer on another thread | Hang forever, no timeout | 🔴 | Timeouts both sides | **G21** Hard timeout on both halves; kill-switch cancel path; tests that kill each side mid-transfer |

### 3.6 Idempotency and retries

| # | Case | Symptom | Sev | Guardrail |
|---|---|---|---|---|
| 42 | Retry after partial upload | `FXF_TRUNC` restarts from byte 0 — **by design, unavoidable today** | 🟡 | **G22** Never label this "resume". UI must say "restart" (see `visual.html` screen 18) |
| 43 | Auto-retry storm against a down server | N tasks × retries hammering a dead host; possible fail2ban ban | 🟠 | **G23** Exponential backoff, per-server (not per-task) circuit breaker, cap ≈30 min |
| 44 | Re-upload of an already-complete file | Safe (truncate + rewrite) but wastes a full transfer | ⚪ | **G24** Compare remote size + mtime before re-sending |
| 45 | Rename succeeded but status not persisted, then crash | Duplicate upload on next launch | 🟡 | **G17** + **G24** |

### 3.7 State, lifecycle, and adjacent features

| # | Case | Where | Sev | Guardrail |
|---|---|---|---|---|
| 46 | History records a local path that no longer exists | `Model/HistoryEntry.swift` | ⚪ | **G25** Record the remote URI |
| 47 | Export/import carries a dangling `connectionID` | `Persistence/AppExport.swift` | 🟡 | **G26** On import, drop `remoteDestination` when the connection is unknown **or the flag is OFF**; never silently retarget |
| 48 | Open / Reveal / Play on a remote-only task | `AppViewModel.swift:1051-1060` | 🟡 | **G27** Replace with "Open on server"; never `NSWorkspace.open` a missing path |
| 49 | Dock/NSProgress skips tasks with no local file | `FileProgressPublisher.swift:24, 55` | ⚪ | **G27** |
| 50 | Delete-with-data on a remote task | Deletes local (already gone), leaves remote | 🟡 | **G27** Ask explicitly whether to delete the remote copy; **default no** |
| 51 | Torrent seeding vs deleting the local copy | Deleting stops seeding | 🟡 | **G28** Keep the staged copy until seeding ends; make it a visible setting |
| 52 | Linux daemon / web portal unaware of the feature | `GoelDaemon`, `RemotePortalPage.swift` | 🟠 | **G5** + flag defaults OFF there too |

---

## 4. Failure modes and how to stop them

Ordered by how quickly they can be stopped.

### 4.1 Master kill switch — the feature setting

`sftpDestinationEnabled = false` disables **all** of it. See §5. This is the blunt
instrument: it stops new remote-destination downloads from being created and stops the
upload stage from running. It does **not** retroactively undo completed uploads.

### 4.2 Per-server circuit breaker (**G23**)

After *k* consecutive failures against one server, stop attempting that server and mark
its queued uploads "held". Prevents retry storms and fail2ban bans. Manual reset, or a
timed half-open probe.

### 4.3 Concurrency caps (**G10**)

A global semaphore bounds concurrent SSH sessions. Because the current model is
**one full handshake per operation with no pooling** (`SFTPClient.swift:47-50`), this is
the difference between an orderly queue and a session storm.

### 4.4 Staging budget (**G19**)

A cumulative cap on staged-but-not-yet-uploaded bytes. When exceeded, new
remote-destination downloads stay queued rather than starting. This is what stops a
down server from silently filling the boot disk. Note #38: segmented HTTP claims the
**full** file size up front, so this must gate at queue time.

### 4.5 Per-task cancel

Cancel must (a) signal the libssh2 thread via the existing `CancelFlag` pattern
(`SFTPBrowserModel.swift:147-152`), (b) await teardown, (c) remove the remote `.part`,
(d) only then release the local copy. Ordering matters — see #23.

### 4.6 Hard stops that must never be overridable

- **Host key mismatch** (#15) — no bypass in the failure dialog.
- **Unattended upload to an unpinned server** (#16) — refuse; require an interactive pin.
- **Remote-control API selecting a destination** (#11) — not a warning, a refusal.

---

## 5. The feature gate

### 5.1 Name, type, default

```swift
/// Allow a download's destination to be a saved SFTP server instead of a local
/// folder. Off by default — a deliberate opt-in: when enabled, finished downloads
/// are transferred to a remote host and the local copy is removed, so it must
/// never switch itself on.
public var sftpDestinationEnabled: Bool
```

- **Name:** `sftpDestinationEnabled`
- **Default:** `false` (OFF)
- **Home:** `Sources/GoelCore/Scheduler/AppSettings.swift`

**Why OFF, and why this shape.** The project has no env vars and no feature-flag
service; `AppSettings` is the established convention. Existing opt-in flags all default
`false` — `autoRedownloadOnRemoteChange` is documented as *"Off by default — a
deliberate opt-in so a finished file is never silently replaced"* (`AppSettings.swift:285-288`),
and `remoteAccessEnabled`, `aggregationEnabled` and `autoRetryEnabled` follow the same
pattern. A flag that moves user data to a third-party host and deletes the local copy is
the strongest possible case for that default.

There is also precedent for **persisting a flag before the feature is wired**:
`proxyAllProtocols` is stored but deliberately not surfaced, with a comment explaining
it is there for a follow-up (`AppSettings.swift:83-87`).

### 5.2 The four-step `AppSettings` pattern

Adding a flag requires all four, or old persisted blobs break:

1. `public var sftpDestinationEnabled: Bool` + doc comment
2. `sftpDestinationEnabled: Bool = false` in `init(...)` (`AppSettings.swift:~369`), and assignment in the body
3. `case sftpDestinationEnabled` in `CodingKeys` (`AppSettings.swift:~570`)
4. `sftpDestinationEnabled = try c.decodeIfPresent(Bool.self, forKey: .sftpDestinationEnabled) ?? false` in `init(from:)` (`AppSettings.swift:~610`)

Step 4 is what makes it backwards compatible — the decoder uses `decodeIfPresent`
throughout precisely so blobs written before a key existed still load.

### 5.3 Where the check goes

Per the "early return at the outermost entry point" rule, so nested code is never
entered:

| Layer | Location | Behaviour when OFF |
|---|---|---|
| **UI — picker** | `AddDownloadSheet.saveOptions` (`:68-80`) | SERVERS group and "Choose remote folder…" are **not built**. No separator, no empty state. |
| **UI — settings** | Destinations pane | Pane hidden except the master toggle itself |
| **UI — detail/list** | badges, two-phase progress | Not rendered |
| **Core — creation** | `DownloadManager.add(...)` (`:429`) | `remoteDestination` argument ignored; task is a plain local download |
| **Core — upload stage** | new stage in `DownloadManager+SideEffects.swift` | Early `return` before any session, preflight or Keychain read |
| **Core — reconcile** | `DownloadManager+FileReconcile.swift` | Remote-aware branch inert; behaves exactly as today |
| **Remote API** | `RemoteRouter.swift:136-148` | Field rejected — **and still rejected when ON** (G5) |
| **Automation** | `DownloadManager+Automation.swift:93` | No remote destinations |
| **Headless adds** | native messaging, AppleScript, watch folders, RSS | No remote destinations |
| **Import** | `AppExport` | `remoteDestination` stripped on import |
| **Linux daemon** | `GoelDaemon` | Same flag, same default |

The core check must **not** live only in the upload stage. If the picker is reachable
while the stage is gated, a user can queue a download that silently never reaches its
destination — worse than not offering it.

### 5.4 Behaviour when the flag is turned OFF with existing state

This is the case most likely to be got wrong, so it is specified explicitly:

| State when flag flips OFF | Required behaviour |
|---|---|
| Task queued, not started | Runs as a **normal local download** into the staging directory. Local copy **kept**. |
| Task downloading | Completes locally. Upload stage does not run. Local copy **kept**. |
| Task uploading | **Drain, do not abandon.** Finish or cleanly cancel the in-flight upload, remove any `.part`, keep the local copy. Never leave a truncated remote file. |
| Task already completed and uploaded | Untouched. Local copy already gone; nothing is re-downloaded. Row remains, marked as remote. |
| Persisted `remoteDestination` on disk | **Preserved, not erased.** Re-enabling must restore intent. |

The invariant: **with the flag OFF, no local file is ever deleted and no byte is ever
sent to a remote host.** "Feature absent" means inert, not destructive.

### 5.5 How to toggle

Settings → Destinations → *"Send downloads to a server"* (master toggle). Persisted via
the normal `AppSettings` path; no restart required.

### 5.6 Verification steps (for when this is implemented)

Existing tests live in `Tests/GoelCoreTests/` (XCTest; `SecurityHardeningTests.swift`
and `FileReconcileTests.swift` are the closest precedents).

**Flag OFF — no side effects**
1. `AppSettings()` default → `sftpDestinationEnabled == false`
2. Decode a settings blob written before the key existed → `false`, no throw
3. `add(...)` with a `remoteDestination` → task has `remoteDestination == nil`
4. Complete a task carrying a persisted `remoteDestination` → assert no `SFTPClient` construction, no Keychain read, no local deletion
5. `POST /api/add` with a destination field → field ignored, 2xx, local default used

**Flag ON — happy path**
6. Relay end-to-end against a local sshd fixture → remote file exists, size matches, local copy gone
7. Reconcile sweep runs → completed remote task **survives** (regression test for #31)

**Guardrails reject bad input**
8. `RemotePathSafety` rejects `../`, empty, control chars, over-length (**G1**, **G3**)
9. Concurrency cap: 20 simultaneous completions → assert ≤ N concurrent sessions (**G10**)
10. Host-key mismatch → upload refused, no credential sent (**G7**)
11. `POST /api/add` with a destination → rejected **even with the flag ON** (**G5**)
12. Staging budget exceeded → new remote downloads stay queued (**G19**)

**Build/lint**
`swift build` and `swift test`. The repo also ships `check_sendable` /
`check_sendable_strict` binaries — the new `RemoteDestination` type must be `Sendable`,
as every model in `GoelCore` is.

---

## 6. Guardrail summary

| ID | Guardrail | Addresses | Ship | Priority |
|---|---|---|---|---|
| G1 | `RemotePathSafety` validator — reject `..`, empty, control chars, relative-without-`.`. Runs on **every component of every nested path**, not just the chosen root (§0.2) | 1, 3, 10 | 1 | 🔴 P0 |
| G4 | Preflight: is-directory, writability, symlink resolution, existence | 5, 6, 7, 8 | 1 | 🔴 P0 |
| G5 | Remote API may never select a destination (allowlist only) | 11, 52 | 1 | 🔴 P0 |
| G7 | Host-key mismatch is a hard stop, no bypass | 15 | 1 | 🔴 P0 |
| G8 | Refuse unattended upload to an unpinned server | 16 | 1 | 🟠 P0 |
| G10 | Concurrency cap on SSH sessions | 19 | 1 | 🟠 P0 |
| G13 | Cancel-before-delete ordering; block rename during upload | 23, 24 | 1 | 🟠 P0 |
| G14 | Defined flag-OFF drain semantics | 25 | 1 | 🟠 P0 |
| G15 | Reconcile sweep must not prune uploaded tasks | 26, 31 | 1\* | 🔴 P0 |
| G16 | `.part` + atomic rename; orphan cleanup on retry | 27, 28, 32, 35 | 1 | 🟠 P0 |
| G6 | Auth error classification + retry budget | 12, 13, 14 | 1 | 🟡 P1 |
| G9 | Handle dangling / edited connection references | 17, 18 | 1 | 🟡 P1 |
| G11 | Per-`(connection, path)` serialisation; unique `.part` names | 21 | 1 | 🟠 P1 |
| G17 | Persist upload intent before first byte; reclaim orphans at launch | 29, 30, 45 | 1 | 🟠 P1 |
| G22 | Never call a restart a "resume" | 42 | 1 | 🟡 P1 |
| G23 | Per-server circuit breaker + exponential backoff | 43 | 1 | 🟠 P1 |
| G27 | Remote-aware Open/Reveal/Play/Delete | 48, 49, 50 | 1 | 🟡 P1 |
| G2 | Remote-side filename re-sanitisation + NFC normalisation | 2, 9 | 1 | 🟡 P2 |
| G18 | libssh2 keepalive on long sessions | 33 | 1 | 🟡 P2 |
| G20 | `gsb_statvfs` wrapper for remote free space | 39 | 1 | 🟡 P2 |
| G24 | Skip re-upload when remote size/mtime already match | 44, 45 | 1 | ⚪ P2 |
| G3 | Path/name length caps | 4 | 1 | ⚪ P3 |
| G19 | Staging budget + hard local preflight | 36, 37, 38 | **2** | 🟠 P0 |
| G12 | Destination participates in dedup identity | 22 | **2** | 🟠 P1 |
| G26 | Import drops unknown/disabled destinations | 47 | **2** | 🟡 P1 |
| G25 | History records the remote URI | 46 | **2** | ⚪ P3 |
| G21 | Bounded ring buffer + dual timeouts | 40, 41 | **3** | 🔴 P0 |
| G28 | Torrent seeding vs cleanup policy | 51 | *deferred* | — |

\* G15 is only strictly required in Ship 1 if right-click deletes the local copy (§0.2).
Build it in Ship 1 regardless — Ship 2 needs it unconditionally, and the failure mode is
a task silently vanishing.

**Ship 1 carries 10 of the 12 P0s.** That is the point of sequencing this way: the
hard correctness and security work lands in the smallest, most testable release, against
a surface with no staging, no scheduler interaction, and no headless callers.

Ship 2 adds one P0 (G19). Ship 3 adds one (G21) — the deadlock-prone ring buffer, kept
deliberately last and fully isolated from everything already shipped.

---

## 7. Residual risks and out of scope

### Residual risks (present even with every guardrail)

1. **Uploads cannot resume.** `LIBSSH2_FXF_TRUNC` is architectural (`ssh_bridge.c:329-332`).
   Until the shim gains `FXF_APPEND` + `seek64`, every interruption restarts the transfer.
   On a large file over a poor link this can mean never converging. **The single biggest
   functional weakness.**
2. **Verification is size-only.** Comparing remote size proves length, not content. A true
   end-to-end checksum needs a remote hash command — which needs an exec channel, which is
   out of scope (§7 below).
3. **Trust in the server is absolute.** Once bytes land, the app has no control over them.
4. **No transactional guarantee across the two hops.** "Uploaded but not yet marked
   complete" is always possible; **G17** narrows the window, it does not close it.
5. **TOFU remains TOFU.** **G8** ensures a human is present at pin time, but the first pin
   is still unverified unless the user checks the fingerprint out of band.
6. **Mode A can put a corrupt file on the server**, because a rolling checksum only fails
   *after* the bytes are already there.

### Explicitly out of scope

- **Torrents.** Excluded from v1 per §0. Brings back libtorrent's opaque storage, the
  many-file session storm (#20), and the seeding-vs-cleanup policy (G28, already decided:
  upload and stop seeding).
- **HLS streaming (Mode A).** Permanently relay-only — segments are concatenated and
  remuxed through AVFoundation, so no interceptable stream exists at any scope.
- **All headless surfaces** — watch folders, RSS, remote-control API, web portal,
  AppleScript, native messaging, `GoelDaemon`. Excluded per §0; the refusals are still
  written and tested.
- **Architecture C (remote-side `curl`).** Needs an SSH exec channel the shim doesn't have;
  materially larger security surface. See `visual.html` §2.
- **Resumable uploads.** Requires `FXF_APPEND` + `seek64` in the C shim.
- **Non-SFTP destinations** (S3, WebDAV, SMB).

---

## 8. Open questions

### Resolved (see §0)

| Question | Answer |
|---|---|
| Primary driver — relay or streaming? | Both; streaming ships last |
| Destination settable after completion? | Yes — and it ships **first** |
| Torrent seeding vs cleanup? | Upload and stop seeding — *deferred, torrents out of v1* |
| `GoelDaemon` parity? | No — macOS interactive UI only |
| Automation targeting servers? | No |
| Which download kinds? | Everything except torrents |

### Also resolved (see §0.2)

| Question | Answer |
|---|---|
| Ship 1 deletes the local copy? | No — keep by default, opt-in checkbox, deletion gated on a verified success sequence |
| Multi-file structure? | Preserve the tree; **G1** validates every component |
| Per-server default folder? | Yes — new `defaultUploadPath: String?`, cascading, always overridable |
| Same-host SFTP→SFTP shortcut? | **Rejected — see below** |

### Rejected: server-side `rename` for same-host SFTP→SFTP

Raised during review as a possible large win, then withdrawn on inspection. Worth
recording *why*, so it is not re-proposed later.

A "download" from server A path X to server A path Y must leave **X in place** — the user
asked to obtain a copy at Y, not to move their file. `rename` moves. Implementing the
shortcut would silently destroy the source, which is the worst class of bug this feature
could ship: irreversible, invisible until noticed, and on data nobody asked to have
touched.

The correct primitive would be a server-side *copy*, which SFTP has no portable form of.
OpenSSH's `copy-data` extension exists but is not universally supported and is not
exposed by libssh2. So the round trip stays.

*(A deliberate "Move on server" action is a reasonable separate feature — and the SFTP
browser already has most of it, since `SFTPClient.rename` works across directories.)*

### Genuinely still open

Nothing blocking. The next open decisions are Ship 2 concerns and can wait until Ship 1
has run against real servers.
