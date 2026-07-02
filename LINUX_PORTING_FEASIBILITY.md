# Goel° — Linux Porting Feasibility Study

**Status:** Planning phase. No production code changed. All findings below are backed by
static analysis of the codebase **and** a real build spike executed on the home server
(Ubuntu 24.04.1, x86_64).

**Date:** 2026-07-02
**Branch / worktree:** `linux-porting-feasibility-study-and-testing`

---

## 1. Verdict

**Feasible — and less risky than it looks.** The four scariest unknowns were tested on the
actual Linux box and all passed. The codebase is cleanly layered (a pure `GoelCore` under a
macOS-only SwiftUI shell), so the download **engine** — every protocol and every queue/scheduler
feature — ports with little change. The realistic deployment model on Linux is a
**headless daemon + the app's existing web portal as the UI**.

> **Important nuance on "no feature loss":** the *engine and management features* port at ~100%.
> The *native macOS desktop shell* (SwiftUI windows, menu-bar extra, Dock progress, Services menu,
> AppleScript, Safari Web Extension, Notification Center, Sparkle auto-update, Drop Basket,
> QuickLook, login-item) is Apple-only and does **not** port as-is. On Linux those roles are
> filled by the **web portal that already ships in the app** (`RemoteRouter` + `RemotePortalPage`
> + `RemotePortalAssets`, which are pure and transport-agnostic today). So: **no download-feature
> loss; the "GUI" becomes the web portal instead of native Cocoa windows.**

Rough effort for full engine parity + web portal on Linux: **~3–4 focused engineering weeks.**

---

## 2. What was tested on the home server (empirical evidence)

Server: **Ubuntu 24.04.1 LTS, kernel 6.17, x86_64**, 4 cores / 31 GB RAM / 74 GB free.
Installed **Swift 6.1** (official swift.org toolchain) + the native `-dev` libraries from apt,
then built and **ran** a spike (`~/work/goel-linux-spike/probe`) exercising the load-bearing parts:

| Risk area | macOS uses | Linux replacement tested | Result on the server |
|---|---|---|---|
| Crypto (checksums, portal password) | CryptoKit / CommonCrypto | `swift-crypto` (`import Crypto`) | `SHA256(hello)=2cf24dba…` ✓ correct |
| BitTorrent native lib | Homebrew libtorrent, hardcoded paths | apt `libtorrent-rasterbar-dev` via **pkg-config** | linked + ran `libtorrent::version()` → `2.0.10.0` ✓ |
| Persistence | GRDB on macOS system SQLite | GRDB on a **snapshot-enabled SQLite** we compiled | real DB roundtrip `rows=2 task1.state=seeding` ✓ |
| Remote portal transport | `Network.framework` (`NWListener`) | **SwiftNIO** `ServerBootstrap` | bound `127.0.0.1:18899`, `curl → goel-nio-ok [HTTP 200]` ✓ |

**Key de-risking detail:** Ubuntu's `libtorrent-rasterbar.pc` emits *exactly* the same ABI
defines the macOS `Package.swift` hardcodes (`TORRENT_USE_OPENSSL`, `TORRENT_SSL_PEERS`,
`BOOST_ASIO_*`, …). libtorrent ABI mismatch is the classic way to get silent corruption; here the
Linux package was built with the same options, and pkg-config hands us the correct flags. Versions
also line up: **libtorrent 2.0.10** (code targets 2.0.x), libssh2 1.11, libcurl 8.5, sqlite 3.45
(system) / 3.53 (our snapshot build), openssl 3.0, boost 1.83 — all present in apt.

The one **GRDB gotcha**, now understood: Ubuntu's stock `libsqlite3` is built **without**
`SQLITE_ENABLE_SNAPSHOT`, so GRDB's WAL-snapshot code fails to link. Fix (validated): link a SQLite
compiled with `-DSQLITE_ENABLE_SNAPSHOT`. The app already vendors native libs into the macOS bundle,
so vendoring a snapshot-enabled SQLite on Linux fits the existing "self-contained" model.

---

## 3. Why the port is contained: architecture

```
GoelApp  (9,621 LoC)  — SwiftUI/AppKit desktop shell     → NOT portable (replaced by web portal)
GoelCore (12,158 LoC) — engines, queue, scheduler,       → PORTABLE (53 of 60 files Foundation-only)
                         persistence, remote portal
C bridges — TorrentBridge / CurlBridge / SSHBridge       → PORTABLE (swap Homebrew paths → pkg-config)
```

Only **7 of 60 `GoelCore` files** touch an Apple-only API. The rest are `import Foundation` only.
The remote server was already refactored into a **pure `RemoteRouter`** (0 `Network` imports —
verified) plus a thin **I/O shell `RemoteControlServer`** that owns the `NWListener`. Platform
side-effects (power, folder-watch, AV scan) already sit behind `Sendable` **ports**
(`PlatformPorts.swift`). This separation is what makes the port a set of adapter swaps rather than a
rewrite.

---

## 4. Port surface — exact files and the plan for each

### 4a. `GoelCore` files needing Linux work (7)

| File | Apple API | Linux approach | Size |
|---|---|---|---|
| `Remote/RemoteControlServer.swift` | `Network.framework` | Rewrite the I/O shell on **SwiftNIO** (proven). `RemoteRouter`/portal untouched. Reimplement: SSE loop, byte-range file streaming, connection caps, sessions. | ~602 LoC, 1 file |
| `Engine/HLSEngine.swift` | `AVFoundation` (remux) + `CommonCrypto` (AES-128) | Remux via **ffmpeg `-c copy`** (ffmpeg 6.1 already on server); AES-128 via **swift-crypto** | 2 sites + AES |
| `Ports/CredentialStore.swift` | `Security` / Keychain | File-based store (`0600`) or **libsecret**; already a Port | ~125 LoC, 1 file |
| `PowerManager.swift` | `IOKit` | Linux adapter: `systemd-inhibit` / no-op; already behind `PowerControlling` | ~1 file |
| `Engine/HTTPEngine+Filename.swift` | `UniformTypeIdentifiers` (MIME→ext) | Small static MIME table or `libmagic` | small shim |
| `ChecksumVerifier.swift` | `CryptoKit` | `#if canImport(CryptoKit) … #else import Crypto` (proven) | trivial |
| `Remote/RemotePassword.swift` | `CryptoKit` | same as above | trivial |

### 4b. Build system (`Package.swift`)

- Gate `.macOS(.v14)` bits; add a Linux platform path.
- C bridges: replace hardcoded `/opt/homebrew/...` `-I`/`-L` flags with **pkg-config** output
  (`libtorrent-rasterbar`, `libssh2`, `libcurl`). Proven to resolve correctly on the box.
- Add `swift-crypto`, `swift-nio` deps (Linux only, or `#if os`).
- Exclude **Sparkle** on Linux (it's a `GoelApp` dep anyway).
- Vendor / link a snapshot-enabled SQLite for GRDB.
- Add `#if canImport(FoundationNetworking) import FoundationNetworking` wherever `URLSession` is used.

### 4c. New Linux entry point

A small headless executable target (`GoelDaemon`): boots `DownloadManager` + the NIO-backed
`RemoteControlServer`, reads config, no SwiftUI. Mirrors `main.swift` minus the GUI. Ships with a
**systemd unit**.

### 4d. `GoelApp` (the SwiftUI shell) — not ported

~9.6k LoC of Cocoa UI stays macOS-only by design. On Linux the **web portal is the UI**. A couple of
small pieces of logic currently living in `GoelApp` would move down into the daemon:
- `YtDlpResolver.swift` — just shells out to the cross-platform `yt-dlp` binary; trivial to relocate.
- Browser-capture: today it uses a native-messaging host; on Linux the extension would POST to the
  **remote-control API** instead (the extension already speaks HTTP to the app).

---

## 5. Feature parity matrix (Linux, headless + web portal)

| Feature | Ports? | Notes |
|---|---|---|
| HTTP/HTTPS segmented, resume, governor, rate-limit | ✅ | `URLSession` → `FoundationNetworking`; validate delegate-streaming path (see §6) |
| Mirrors / Metalink | ✅ | Pure logic |
| BitTorrent (libtorrent: magnets, DHT/PeX/µTP, seeding) | ✅ | Native lib proven to link/run |
| FTP/FTPS (libcurl) | ✅ | apt libcurl via pkg-config |
| SFTP + file browser (libssh2) | ✅ | apt libssh2 via pkg-config |
| HLS video | ✅ | Remux swaps AVFoundation → ffmpeg |
| Unified queue, priorities, traffic profiles | ✅ | Pure `GoelCore` |
| Scheduler, watch folder, post-download actions, AV scan | ✅ | `Process`/`DispatchSource` work on Linux |
| Checksums, history, backup/export (CSV) | ✅ | swift-crypto + GRDB |
| Remote web portal (list/add/control, SSE, themes, sign-in) | ✅ | Router is pure; transport → NIO |
| yt-dlp resolver | ✅ | Cross-platform binary; move into daemon |
| Browser capture (Chrome/Edge/Brave/Firefox) | ⚠️ | Point extension at remote API instead of native-messaging host |
| Native SwiftUI windows / menu-bar / Dock / Drop Basket | ❌ | macOS shell → replaced by web portal |
| Services menu, AppleScript, `goeldownloader://`, Safari ext | ❌ | macOS-only integrations |
| Notification Center | ❌→⚠️ | Optional: swap for `notify-send` / portal notifications |
| Sparkle auto-update | ❌ | Use apt/tarball/manual on Linux |
| Power/battery awareness | ⚠️ | Server context: mostly N/A; `systemd-inhibit` if desired |

---

## 6. Risks & things still to validate

1. **`URLSession` on Linux (highest remaining risk).** HTTP is the primary engine and is built on
   `URLSession` with a streaming `URLSessionDataDelegate`. Linux `URLSession` (swift-corelibs-foundation,
   libcurl-backed) is mature but historically has delegate/config gaps. **Cheap to validate now** — the
   Swift toolchain is already on the server; next step is a spike that runs a real segmented ranged
   download through the actual `HTTPEngine`.
2. **libtorrent Swift/C++ interop surface.** The spike proved link+call of one symbol. The real
   `TorrentBridge` is larger; expect minor header/flag adjustments, but pkg-config gives the right base.
3. **GRDB SQLite feature flags.** Beyond snapshot, confirm the app's SQLite feature usage (FTS, etc.)
   is covered by the vendored build. Bounded and known.
4. **swift-corelibs-foundation edge behaviors** (date/locale/`FileManager` resource values) — usually
   fine; verify during integration.
5. **Distribution size.** Self-contained Linux build must vendor libtorrent/ssh2/curl/SQLite closure
   (as macOS already does) or declare apt dependencies.

---

## 7. Recommended phased plan

- **Phase 0 — De-risk (½ week):** run the real `HTTPEngine` + `TorrentBridge` on the server (toolchain
  already installed). This closes risk #1 and #2 before committing to the full port.
- **Phase 1 — Buildable core (1 wk):** `Package.swift` Linux path (pkg-config, swift-crypto/nio,
  `FoundationNetworking`, snapshot SQLite, exclude Sparkle). Get `GoelCore` to compile on Linux.
- **Phase 2 — Adapter swaps (1 wk):** crypto, MIME, PowerManager, CredentialStore, HLS/ffmpeg.
- **Phase 3 — Portal transport + daemon (1 wk):** NIO rewrite of `RemoteControlServer`; `GoelDaemon`
  target + systemd unit; browser-capture via remote API.
- **Phase 4 — Package & verify (½–1 wk):** `.deb`/tarball, vendored-lib closure, end-to-end parity test.

---

## 8. Home-server footprint (from this study)

Left under `~/work/goel-linux-spike/` on the server:
- `swift/` — Swift 6.1 toolchain (~1.6 GB extracted) + `swift.tar.gz` (840 MB)
- `probe/` — the working spike package (+ `.build`)
- `sqlite/` — snapshot-enabled `libsqlite3.so` + amalgamation
- `logs/` — build/run logs

Also `apt-get install`ed (system-wide, harmless/reusable dev libs): `libtorrent-rasterbar-dev`,
`libssh2-1-dev`, `libcurl4-openssl-dev`, `libsqlite3-dev`, `libssl-dev`, `libboost*-dev`, plus Swift
runtime deps. **Nothing else on the server was touched; no services modified.** The spike directory
can be removed at any time; the toolchain can stay if we proceed to Phase 0.
