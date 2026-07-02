<div align="center">

<img src="Assets/AppIcon-Light-1024.png" width="128" height="128" alt="Goel° app icon — a white “g” monogram with a raised accent dot on a sky-blue squircle" />

# Goel°

**A fast, native macOS download manager that unifies HTTP, FTP, SFTP, BitTorrent, and HLS in one queue.**

Inspired by Free Download Manager — rebuilt from scratch in Swift, self-contained, and Homebrew-free.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## What is Goel°?

A native SwiftUI download manager for macOS. Direct downloads and torrents share **one unified queue**
and one interface — the same list, detail panel, and controls whether you're pulling a file over HTTPS
or seeding a torrent. It ships as a **single self-contained app**: every native library is bundled
inside, so there is nothing for your users to install.

---

## Features

- **One unified queue** — HTTP/HTTPS, FTP/FTPS, SFTP, BitTorrent, and HLS downloads share one list and one interface.
- **Segmented HTTP** — adaptive multi-connection downloads with resume, mirror/Metalink failover, and rate limiting.
- **Full BitTorrent** — `.torrent` files and magnets via libtorrent, per-file priority, and complete seeding controls.
- **SFTP browser** — browse, upload, and download on remote servers with host-key pinning.
- **HLS video** — download streaming video to a clean `.mp4`.
- **Easy adding** — clipboard auto-paste, batch add, drag & drop, a floating Drop Basket, a web-page Link Grabber, and an optional bundled `yt-dlp` resolver.
- **Queue management** — sortable/filterable list, a detail panel with live speed graphs, and Low/Medium/High traffic profiles.
- **Browser integration** — capture downloads from Chrome/Edge/Brave/Firefox and Safari extensions.
- **macOS native** — menu-bar extra, Dock progress, Services menu, URL scheme, AppleScript, and notifications.
- **Automation** — watch folders, scheduled download windows, power/network awareness, and post-download actions (extract, script, antivirus scan).
- **Remote control** — an optional token-authenticated local HTTP server to manage downloads from another device.
- **Checksums & history** — MD5/SHA verification plus searchable, re-downloadable history with CSV export.
- **Self-contained** — every native library is bundled; no Homebrew or dependencies for end users.

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

## Updating

- **Sparkle** — the bundled auto-update framework; point it at an appcast for silent in-app updates.
- **Built-in checker** — a lightweight GitHub-Releases feed check. Configure the feed URL in
  **Settings → Advanced**.

Third-party libraries are frozen at build time and travel inside each release; there is no separate
library updater by design.

---

## License

Goel° is released under the **MIT License** — © 2026 Vinit Kumar Goel; see **[LICENSE](LICENSE)**.

The app bundles several third-party open-source components (libtorrent, OpenSSL, libssh2, Boost, GRDB,
Sparkle, and optionally yt-dlp), each under its own license. Full attributions are in
**[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**, which also ships inside the app.

> You are responsible for ensuring your use of this software — including what you download — complies
> with applicable law and the terms of service of the sites and networks you use.
