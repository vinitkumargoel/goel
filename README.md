<div align="center">

<img src="Assets/AppIcon-Light-1024.png" width="128" height="128" alt="Goel° app icon — a white “g” monogram with a raised accent dot on a sky-blue squircle" />

# Goel°

**A fast, native macOS download manager that unifies HTTP, FTP, SFTP, BitTorrent, and HLS in one queue.**

Rebuilt from scratch in Swift, self-contained, and Homebrew-free. Native SwiftUI on macOS; a headless daemon with a web-portal UI on Linux.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20Linux-blue)
![Arch](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<br>

<a href="Assets/videos/goel-keynote-demo.mp4"><img src="Assets/videos/goel-keynote-poster.jpg" width="900" alt="Watch the Goel° demo — a 49-second cinematic tour: one unified queue (HTTP, FTP, SFTP, BitTorrent, HLS), live progress and speed, the BitTorrent piece map, browser-extension capture, and menu-bar + web-portal access. Click to play." /></a>

<sub><i>▶ <b><a href="Assets/videos/goel-keynote-demo.mp4">Watch the 49-second demo</a></b> 🔊 · downloads shown are illustrative mock data</i></sub>

</div>

---

## What is Goel°?

A native SwiftUI download manager for macOS. Direct downloads and torrents share **one unified queue**
and one interface — the same list, detail panel, and controls whether you're pulling a file over HTTPS
or seeding a torrent. It ships as a **single self-contained app**: every native library is bundled
inside, so there is nothing for your users to install.

On **Linux**, the same engine runs headless as **`GoelDaemon`**, driven from the built-in web portal — see [Linux (headless daemon)](#linux-headless-daemon).

---

## Screenshots

**macOS app** — the native SwiftUI app: one unified queue, a Library/Status/Type sidebar with live counts, and a detail panel with a circular progress ring, live speeds, and per-file facts.

<img src="Assets/screenshots/desktop.png" width="900" alt="Goel° on macOS — one unified queue mixing HTTP, BitTorrent, SFTP, HLS and FTP; a Library/Status/Type sidebar with live counts; and a detail panel with a 62% progress ring, down/up speeds, and file facts." />

**Linux web portal** — the same engine, headless, driven from any browser. Token- or password-authenticated, with the same unified queue, detail panel, and four themes as the desktop app.

<img src="Assets/screenshots/web-portal.png" width="900" alt="Goel° web portal in a browser — topbar with search, live down/up totals and an Add button; a sidebar of Library/Status filters with counts; the unified download list; and a detail panel with progress, save path, and source for the selected download." />

**macOS menu-bar extra** — glance at active downloads and pause/resume or add new ones without opening the main window.

<img src="Assets/screenshots/menubar.png" width="460" alt="Goel° macOS menu-bar popover — an 'Active · 4' header with global down/up speeds, four in-progress downloads each with a progress bar and speed, and a footer with Add download, Pause all, and Open Goel°." />

<sub><i>All downloads shown are illustrative mock data.</i></sub>

---

## Features

- **One unified queue** — HTTP/HTTPS, FTP/FTPS, SFTP, BitTorrent, and HLS downloads share one list and one interface.
- **Segmented HTTP** — adaptive multi-connection downloads with resume, mirror/Metalink failover, and rate limiting.
- **Full BitTorrent** — `.torrent` files and magnets via libtorrent, per-file priority, and complete seeding controls.
- **SFTP browser** — browse, upload, and download on remote servers with host-key pinning.
- **HLS video** — download streaming video to a clean `.mp4`.
- **Easy adding** — clipboard auto-paste, batch add, drag & drop, a floating Drop Basket, and a web-page Link Grabber.
- **Queue management** — sortable/filterable list, a detail panel with live speed graphs, and Low/Medium/High traffic profiles.
- **Browser integration** — capture downloads from Chrome/Edge/Brave/Firefox and Safari extensions.
- **macOS native** — menu-bar extra, Dock progress, Services menu, URL scheme, AppleScript, and notifications.
- **Automation** — watch folders, scheduled download windows, power/network awareness, and post-download actions (extract, script, antivirus scan).
- **Remote control** — an optional token-authenticated local HTTP server to manage downloads from another device.
- **Checksums & history** — MD5/SHA verification plus searchable, re-downloadable history with CSV export.
- **Self-contained** — every native library is bundled; no Homebrew or dependencies for end users.
- **Runs headless on Linux** — the same engine runs as a daemon (`GoelDaemon`) with the web portal as its UI.

---

## Installation (macOS)

> **Requires a Mac on macOS 14 (Sonoma) or later** — Apple Silicon **or** Intel.

1. Download the latest `.dmg` for your Mac from
   [Releases](https://github.com/vinitkumargoel/goel/releases):
   **`Goel-Downloader-<version>-macos-arm64.dmg`** (Apple Silicon) or
   **`…-macos-x86_64.dmg`** (Intel).
2. Open the `.dmg` and drag **Goel°** to **Applications**.
3. Launch it.

Everything the app needs is bundled — **no Homebrew or libraries required.**

**First-launch note (Gatekeeper):** a notarized release just opens. For an un-notarized build (e.g. a
beta), right-click the app → **Open** → **Open**, or run once:
```bash
xattr -dr com.apple.quarantine "/Applications/Goel°.app"
```

---

## Linux (headless daemon)

On Linux, Goel° runs as a headless service — **`GoelDaemon`** — with the built-in **web portal as its UI**.
The same engine (HTTP, FTP, SFTP, BitTorrent, HLS, scheduler, persistence) runs behind a token- or
password-authenticated web server that you drive from any browser.

### Install (prebuilt tarball)

> **Prebuilt for x86_64.** For ARM64, [build from source](#build-from-source).

1. Download **`goel-daemon-<version>-linux-x86_64.tar.gz`** from
   [Releases](https://github.com/vinitkumargoel/goel/releases) and unpack it:
   ```bash
   tar xzf goel-daemon-<version>-linux-x86_64.tar.gz
   cd goel-daemon-<version>-linux-x86_64
   ```
2. Install the runtime libraries (Ubuntu 24.04):
   ```bash
   sudo apt-get install -y \
     libtorrent-rasterbar2.0 libssh2-1 libcurl4 libssl3 libboost-system1.83.0 ffmpeg
   ```
3. Run it — `run.sh` bundles the Swift runtime, so **no toolchain needed**:
   ```bash
   GOEL_PORT=8080 \
   GOEL_ALLOW_LAN=true \
   GOEL_USERNAME=admin \
   GOEL_PASSWORD='choose-a-strong-one' \    # required before it will expose over the LAN
   GOEL_SAVE_DIR="$HOME/Downloads" \
     ./run.sh
   # then open http://<host>:8080, sign in, and add downloads
   ```

Config env vars: `GOEL_PORT`, `GOEL_ALLOW_LAN`, `GOEL_REQUIRE_AUTH`, `GOEL_USERNAME`, `GOEL_PASSWORD`,
`GOEL_SAVE_DIR`, `GOEL_DB`. With sign-in enabled, LAN exposure requires `GOEL_PASSWORD` (otherwise it
binds loopback only — the same safety rule as macOS).

### Build from source

You only need this to build the daemon yourself (or for ARM64). **Prerequisites** (Ubuntu 24.04):
```bash
sudo apt-get install -y \
  libtorrent-rasterbar-dev libssh2-1-dev libcurl4-openssl-dev \
  libssl-dev libboost-dev libboost-system-dev libsqlite3-dev \
  clang pkg-config ffmpeg
# plus a Swift toolchain from https://swift.org/download
```

**Build:**
```bash
Scripts/linux/build-sqlite.sh            # once — snapshot-enabled SQLite that GRDB needs
export GOEL_SQLITE_DIR="$PWD/Vendor/linux/sqlite"
swift build -c release --product GoelDaemon
```

Run the result the same way as above, pointing at `./.build/release/GoelDaemon` instead of `./run.sh`.
If the Swift runtime isn't on the library path, prefix the run with
`LD_LIBRARY_PATH=<toolchain>/usr/lib/swift/linux`.

---

## Building the macOS app from source

> **Just want to run it?** Download the `.dmg` from
> [Releases](https://github.com/vinitkumargoel/goel/releases) — this section is only for
> building the app yourself.

You need Homebrew **only to build** — the resulting `.app` is self-contained.

```bash
# 1. Native libraries the engines link against
brew install libtorrent-rasterbar openssl@3 libssh2 boost

# 2. Debug build / run
swift build
swift run GoelDownloader

# 3. Assemble a distributable, self-contained .app (vendors dylibs, strips, signs)
Scripts/build_app.sh          # → dist/Goel°.app  (+ a .zip)

# 4. Wrap it in a drag-to-Applications disk image
Scripts/make_dmg.sh           # → dist/Goel-Downloader-<version>-macos-arm64.dmg
```

**Signing & notarization** (for public distribution) — provide Apple Developer credentials:
```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-keychain-profile" \
Scripts/build_app.sh
```
This signs with hardened runtime + the entitlements in `Scripts/Goel.entitlements`, submits to Apple's
notary service, and staples the ticket — which is what lets a downloaded app open without warnings.

## Updating

- **Sparkle** — the bundled auto-update framework; point it at an appcast for silent in-app updates.
- **Built-in checker** — a lightweight GitHub-Releases feed check. Configure the feed URL in
  **Settings → Advanced**.

Third-party libraries are frozen at build time and travel inside each release; there is no separate
library updater by design.

---

## License

Goel° is released under the **MIT License** — © 2026 Vinit Kumar Goel; see **[LICENSE](LICENSE)**.
