# Goel° — Linux Port Status & Runbook

Companion to `LINUX_PORTING_FEASIBILITY.md`. That doc was the plan; this is what's
actually implemented and verified running on Linux (Ubuntu 24.04, x86_64).

All Linux code is behind `#if os(Linux)` / `#if canImport(...)`; the macOS build
paths are untouched (see the caveat in "Remaining", the macOS build still needs a
real macOS compile to confirm).

---

## ✅ Implemented and verified running on Linux

Booted the headless `GoelDaemon` and drove it through the web portal API:

| Proof | Result |
|---|---|
| `GoelCore` compiles on Linux | whole core (all engines, scheduler, persistence, router, NIO server) ✓ |
| `GoelDaemon` builds + boots | binds the portal, listening ✓ |
| Portal auth — token | `Authorization: Bearer <token>` → JSON API ✓ |
| Portal auth — password login | `POST /login` → `{"ok":true}` → session cookie → `GET / → 200`; wrong password rejected ✓ |
| Unauthed gating | `GET /` → `303 /login`; login page renders ✓ |
| **HTTP** download (segmented) | added via `POST /api/add` → Completed; **sha256 == curl** (byte-perfect) ✓ |
| **FTP** download (libcurl) | `ftp://ftp.gnu.org/.../hello-2.12.tar.gz` → Completed (1017723 B) ✓ |
| **BitTorrent** (libtorrent) | `.torrent` URL → metadata resolved (6.3 GB exact) → Downloading from peers ✓ |
| Persistence (GRDB + snapshot SQLite) | tasks stored/restored in `queue.sqlite` ✓ |
| **SSE** live stream | `GET /api/events` pushes `data: [{...}]` frames ✓ |

## 🟡 Compiles on Linux, not yet runtime-verified

- **SFTP** engine (libssh2) — compiled + links; needs a test SFTP server to exercise.
- **HLS** download + ffmpeg remux + OpenSSL AES-128 — compiled; needs an HLS URL to exercise end to end.
- **Watch folder**, **scheduler windows**, **post-download actions** (auto-extract / run script / antivirus) — compiled; not exercised on Linux.
- Portal **HTML/JS in a real browser** — verified via `curl`; not yet clicked through a browser.

## ⬜ Remaining for full parity + shipping

- **Packaging**: a systemd unit + `.deb`/tarball; vendor the native-lib + Swift-runtime closure for a self-contained bundle (≈90 MB; see feasibility §1–2). Right now it runs from the build tree with `LD_LIBRARY_PATH` set.
- **Browser-capture extension** → point it at the remote-control API instead of the macOS native-messaging host.
- **yt-dlp resolver** → relocate from `GoelApp` into the daemon (it just shells out to the cross-platform `yt-dlp` binary).
- **macOS build re-verification** — all changes are guarded, but a real macOS `swift build` should confirm nothing regressed. (Also: the Linux `RemoteControlServer` duplicates the pure session/login logic from the macOS shell; a later refactor could share it.)

---

## How to build & run on Linux

Prerequisites (Ubuntu 24.04, developer machine):

```bash
sudo apt-get install -y \
  libtorrent-rasterbar-dev libssh2-1-dev libcurl4-openssl-dev \
  libssl-dev libboost-dev libboost-system-dev libsqlite3-dev \
  clang pkg-config ffmpeg
# Swift 6.1 toolchain from swift.org (ubuntu2404 x86_64)
```

Build:

```bash
# 1. Build the snapshot-enabled SQLite GRDB needs (once).
Scripts/linux/build-sqlite.sh            # -> Vendor/linux/sqlite/libsqlite3.so

# 2. Build the daemon.
export GOEL_SQLITE_DIR="$PWD/Vendor/linux/sqlite"
swift build --product GoelDaemon         # add -c release for a stripped build
```

Run (env-configured):

```bash
GOEL_PORT=8080 \
GOEL_ALLOW_LAN=true \
GOEL_USERNAME=admin \
GOEL_PASSWORD='choose-a-strong-one' \   # required to expose over LAN
GOEL_SAVE_DIR="$HOME/Downloads" \
LD_LIBRARY_PATH="<swift>/usr/lib/swift/linux:$GOEL_SQLITE_DIR" \
  ./.build/debug/GoelDaemon
# open http://<host>:8080  → sign in → add downloads
```

Env vars: `GOEL_PORT`, `GOEL_ALLOW_LAN`, `GOEL_REQUIRE_AUTH`, `GOEL_USERNAME`,
`GOEL_PASSWORD`, `GOEL_SAVE_DIR`, `GOEL_DB`. With sign-in required, LAN exposure
needs `GOEL_PASSWORD` set (else it binds loopback only — same safety rule as macOS).
