<div align="center">

<img src="Assets/AppIcon-Light-1024.png" width="128" height="128" alt="Goel° app icon — a white “g” monogram with a raised accent dot on a sky-blue squircle" />

# Goel°

**A fast, native macOS download manager that unifies HTTP, FTP, SFTP, BitTorrent, and HLS in one queue.**

Inspired by Free Download Manager — rebuilt from scratch in Swift, self-contained, and Homebrew-free.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)
![License](https://img.shields.io/badge/license-Proprietary-lightgrey)

</div>

---

## What is Goel°?

A native SwiftUI download manager for macOS. Direct downloads and torrents share **one unified queue**
and one interface — the same list, detail panel, and controls whether you're pulling a file over HTTPS
or seeding a torrent. It ships as a **single self-contained app**: every native library is bundled
inside, so there is nothing for your users to install.

---

## Features

**Protocols & engines**
- **HTTP/HTTPS** — segmented multi-connection downloads (adaptive 4–16), resume with ETag/Last-Modified
  validation, a governor that backs off on `429`, and shared aggregate rate limiting.
- **Mirrors & Metalink** — round-robin segments across mirrors with health tracking and failover; parses `.meta4` / `.metalink`.
- **BitTorrent** — real libtorrent: `.torrent` and magnets, per-file priority, DHT/PeX/LPD/µTP, wire
  encryption, sequential or rarest-first, piece verification, full seeding controls.
- **FTP/FTPS** — system libcurl, explicit/implicit TLS, REST-based resume.
- **SFTP** — libssh2 with trust-on-first-use host-key pinning and an interactive server file browser.
- **HLS video** — parses playlists, picks the best variant, handles AES-128 and fMP4/TS remux to `.mp4`.

**Getting downloads in** — two-step add flow with clipboard auto-paste and metadata preview; batch add
(paste many URLs/magnets or import a text file); drag & drop onto the window or the floating **Drop
Basket**; **Link Grabber** to extract all links from a web page; optional bundled **`yt-dlp`** resolver;
MD5/SHA-1/SHA-256 checksum verification.

**Managing the queue** — sortable/filterable/searchable list with multi-select; a **Detail panel**
(General, Details, Progress with live speed graph, Files, Connections); **Low/Medium/High traffic
profiles**; menu-bar extra and Dock progress.

**Automation & integration** — browser capture (Manifest V3 for Chrome/Edge/Brave/Firefox + a Safari
Web Extension); macOS Services entry, `goeldownloader://` URL scheme, `magnet:`/`.torrent` handling,
AppleScript, and notifications; watch folder, scheduled windows, auto-shutdown/sleep/quit; power &
network awareness; post-download actions (extract, script, antivirus); optional token-authed remote
control server; searchable re-downloadable history with CSV export and auto-backup.

**Settings** — full panes for General, Network, Traffic Limits, BitTorrent, Scheduler, Advanced,
Antivirus, Browser Integration, and Remote Access.

---

## Installation

> **Requires an Apple Silicon Mac (M1 or later) on macOS 14 (Sonoma) or later.** Intel is not supported.

1. Download the latest **`Goel-Downloader-<version>-macos-arm64.dmg`** from
   [Releases](https://github.com/vinitkumargoel/goel-downloader/releases).
2. Open the `.dmg` and drag **Goel°** to **Applications**.
3. Launch it.

Everything the app needs is bundled — **no Homebrew or libraries required.**

**First-launch note (Gatekeeper):** a notarized release just opens. For an un-notarized build (e.g. a
beta), right-click the app → **Open** → **Open**, or run once:
```bash
xattr -dr com.apple.quarantine "/Applications/Goel°.app"
```

**Video-site downloads (yt-dlp):** the “Resolve Media with yt-dlp” button turns a video-site page into
a direct download. Official releases bundle `yt-dlp`; otherwise install it yourself (`brew install yt-dlp`).

---

## Building from source

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

**Bundling toggle:** `BUNDLE_YTDLP=0 Scripts/build_app.sh` builds without the ~35 MB yt-dlp binary.

---

## Architecture

Four layers, cleanly separated:

```
┌──────────────────────────── GoelApp (SwiftUI) ────────────────────────────┐
│  Windows · menu-bar · Drop Basket · SFTP browser · Settings · Services ·   │
│  URL scheme · AppleScript · notifications · Sparkle · browser extension    │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │  observes a live task stream
┌───────────────────────────────────▼──────────── GoelCore ──────────────────┐
│  Scheduler / DownloadManager — one unified queue, concurrency, priorities,  │
│  traffic profiles, power/network/schedule automation (pure AutomationCore)  │
│  Persistence (GRDB/SQLite) — tasks, resume blobs, settings, history         │
│  Ports — power / folder-watch / file-scan behind protocols (testable)       │
│  Engines — HTTP · FTP · SFTP · HLS · BitTorrent, one shared task model      │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │  thin C shims
        TorrentBridge (libtorrent) · CurlBridge (libcurl) · SSHBridge (libssh2)
```

- **One unified task model.** Every engine presents the same `DownloadTask` upward, so the UI never
  special-cases torrent vs file.
- **Native library symbols stay sealed inside their engines**, reached only through the C shims.
- **Self-contained.** `Scripts/bundle_dylibs.sh` vendors the full native-library closure into
  `Goel°.app/Contents/Frameworks/` and rewrites it to load from inside the bundle.

---

## Updating

- **Sparkle** — the bundled auto-update framework; point it at an appcast for silent in-app updates.
- **Built-in checker** — a lightweight GitHub-Releases feed check. Configure the feed URL in
  **Settings → Advanced**.

Third-party libraries are frozen at build time and travel inside each release; there is no separate
library updater by design.

---

## License

Goel° is © 2026 Vinit Kumar Goel — see **[LICENSE](LICENSE)**.

The app bundles several third-party open-source components (libtorrent, OpenSSL, libssh2, Boost, GRDB,
Sparkle, and optionally yt-dlp), each under its own license. Full attributions are in
**[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**, which also ships inside the app.

> You are responsible for ensuring your use of this software — including what you download — complies
> with applicable law and the terms of service of the sites and networks you use.
