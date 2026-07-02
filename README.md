<div align="center">

<img src="Assets/AppIcon-Light-1024.png" width="128" height="128" alt="Goel° app icon — a white “g” monogram with a raised accent dot on a sky-blue squircle" />

# Goel°

**A fast, native macOS download manager that unifies HTTP, FTP, SFTP, BitTorrent, and HLS in one queue.**

Inspired by Free Download Manager — rebuilt from scratch in Swift, self-contained, and Homebrew-free for the people who install it.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-black)
![Swift](https://img.shields.io/badge/Swift-5.10-orange)
![License](https://img.shields.io/badge/license-Proprietary-lightgrey)

</div>

---

## What is Goel°?

Goel° is a native SwiftUI download manager for macOS. Direct downloads and torrents live in **one
unified queue** with one interface — the same list, the same detail panel, the same controls, whether
you're pulling a file over HTTPS or seeding a torrent. It's built to be **configurable enough that a
Free Download Manager user can switch and never look back**, and it ships as a **single self-contained
app**: every native library it needs is bundled inside, so there is nothing for your users to install.

The mark is a monoline **“g”** monogram with a raised accent dot — the degree sign in *Goel°* — in
white on a sky-blue squircle. The same icon ships for both light and dark appearances.

---

## Features

### Protocols & engines
- **HTTP / HTTPS** — segmented multi-connection downloads (adaptive 4–16 connections), resume with
  ETag/Last-Modified validation, an adaptive connection governor that backs off on `429`, and shared
  aggregate rate limiting.
- **Mirrors & Metalink** — spread segments round-robin across mirror URLs with per-mirror health
  tracking and automatic failover; parses `.meta4` / `.metalink`.
- **BitTorrent** — real libtorrent engine: `.torrent` files **and** magnet links, per-file selection
  and priority, DHT / PeX / LPD / µTP, wire encryption, sequential (streamable) or rarest-first order,
  piece verification, and full seeding controls (upload cap, seed-ratio limits, distinct seeding state).
- **FTP / FTPS** — via system libcurl, with explicit/implicit TLS and REST-based resume.
- **SFTP** — via libssh2, with trust-on-first-use host-key pinning and an interactive **server file
  browser** (navigate, upload, download, make folders).
- **HLS video** — parses master/media playlists, picks the best variant up to your max height, handles
  AES-128 decryption and fMP4/TS remuxing to a clean `.mp4`.

### Getting downloads in
- **Two-step add flow** with clipboard auto-paste and a metadata **preview** (name, size, file list)
  before the download starts.
- **Batch add** — paste many URLs/magnets at once, or import from a text file.
- **Drag & drop** links or `.torrent` files onto the window or the floating **Drop Basket**.
- **Link Grabber** — fetch a web page and extract all downloadable links, grouped by type.
- **Optional `yt-dlp` resolver** — turn a video-site page into a direct downloadable stream (bundled,
  or falls back to your own install — see [below](#video-site-downloads-yt-dlp)).
- **Checksums** — verify MD5/SHA-1/SHA-256 after download (from a header, a `.sha256` sidecar, or one
  you paste in).

### Managing the queue
- Sortable, filterable, searchable download list (by type and by status: active / paused / completed /
  seeding), with multi-select and a full context menu.
- **Detail panel** with tabs: **General**, **Details** (info hash, trackers, peers), **Progress**
  (with a live speed graph), **Files** (torrent tree / HTTP segments), and **Connections** (live peers
  and segments with per-connection stats).
- **Traffic-limit profiles** — switchable **Low / Medium / High** presets covering download/upload
  caps, connection limits, simultaneous-download count, and seed ratio, plus a status-bar “snail”
  toggle for Unlimited ↔ active profile.
- **Menu-bar extra** and **Dock** progress — active count, aggregate speeds, and a Dock progress bar.

### Automation & integration
- **Browser capture** — a Manifest V3 extension (Chrome / Edge / Brave / Firefox) and a **Safari Web
  Extension**: toggle global download capture from the toolbar, or right-click any link/image/video/
  audio to send it to Goel°.
- **macOS integration** — “Download with Goel°” in the **Services** menu, a `goeldownloader://` URL
  scheme, `magnet:` and `.torrent` handling, **AppleScript** support, and Notification Center alerts.
- **Watch folder** for new `.torrent` files; **scheduled download windows** (time-of-day + days);
  **auto-shutdown / sleep / quit** when the queue drains.
- **Power & network awareness** — prevent sleep while downloading, pause under a battery threshold,
  don't seed on battery, pause on expensive/constrained networks.
- **Post-download actions** — auto-extract archives, run a custom script, optional antivirus scan.
- **Remote control** — an optional token-authenticated local HTTP server (loopback or LAN) to list,
  add, and control downloads, with live server-sent events.
- **Backup & history** — persistent completed-download history (searchable, re-downloadable, CSV
  export), export/import of the queue and settings, and periodic auto-backup.

### Settings
Full preference panes: **General**, **Network** (proxy, timeouts, user-agent, per-host credentials),
**Traffic Limits**, **BitTorrent**, **Scheduler**, **Advanced** (notifications, power, backup,
updates), **Antivirus**, **Browser Integration**, and **Remote Access**.

---

## Installation

> **Requirements: an Apple Silicon Mac (M1 or later), running macOS 14 (Sonoma) or later.**
> Intel Macs are not currently supported.

1. Download the latest **`Goel-Downloader-<version>-macos-arm64.dmg`** from the
   [Releases](https://github.com/vinitkumargoel/goel-downloader/releases) page.
2. Open the `.dmg` and drag **Goel°** to your **Applications** folder.
3. Launch it.

Everything the app needs is bundled inside it — **you do not need Homebrew or any libraries installed.**

### First-launch note (Gatekeeper)

If the release you downloaded is **notarized**, it just opens. If you're running an **un-notarized**
build (e.g. a beta), macOS may say *“Goel° can't be opened because Apple cannot check it…”*. To open it:

- **Right-click** the app → **Open** → **Open**, or
- run once in Terminal:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/Goel°.app"
  ```

See [SHIPPING.md](SHIPPING.md) for the full distribution/notarization story.

### Video-site downloads (yt-dlp)

The “Resolve Media with yt-dlp” button turns a video-site page into a direct download. Official
releases **bundle `yt-dlp` inside the app**, so this works out of the box. If you build without it,
the button simply appears once you install yt-dlp yourself (`brew install yt-dlp`).

---

## Building from source

You only need Homebrew **to build** — the resulting `.app` is self-contained and its users do not.

```bash
# 1. Install the native libraries the engines link against
brew install libtorrent-rasterbar openssl@3 libssh2 boost

# 2. Debug build / run
swift build
swift run GoelDownloader

# 3. Assemble a distributable, self-contained .app
#    (vendors the native dylibs into the bundle, strips, signs)
Scripts/build_app.sh          # → dist/Goel°.app  (+ a .zip)

# 4. Wrap it in a drag-to-Applications disk image
Scripts/make_dmg.sh           # → dist/Goel-Downloader-<version>-macos-arm64.dmg
```

### Signing & notarization (for public distribution)

The build script is notarization-ready — just provide your Apple Developer credentials:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-keychain-profile" \
Scripts/build_app.sh
```

This signs everything with hardened runtime + the entitlements in `Scripts/Goel.entitlements`, then
submits to Apple's notary service and staples the ticket. **This is what makes a downloaded app open
without warnings.** Full details and the ship-ready checklist are in **[SHIPPING.md](SHIPPING.md)**.

### Bundling toggle

```bash
BUNDLE_YTDLP=0 Scripts/build_app.sh   # build without the ~35 MB yt-dlp binary
```

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

- **One unified task model.** Every engine presents the same `DownloadTask` upward — multi-file,
  up/down bytes and speeds, a distinct seeding state, a pre-metadata state for magnets, and concrete
  persistable failure reasons — so the UI never special-cases torrent vs file.
- **Native library symbols stay sealed inside their engines**, reached only through the C shims.
- **The app is self-contained.** `Scripts/bundle_dylibs.sh` vendors the full native-library closure
  into `Goel°.app/Contents/Frameworks/` and rewrites it to load from inside the bundle — no Homebrew
  on the user's machine.

---

## Updating

Goel° includes two update paths (see [SHIPPING.md §7](SHIPPING.md)):

- **Sparkle** — the bundled auto-update framework; point it at an appcast (e.g. hosted on GitHub Pages)
  for silent in-app “Update & Relaunch”.
- **Built-in checker** — a lightweight GitHub-Releases feed check that offers a manual download when a
  newer version ships. Configure the feed URL in **Settings → Advanced**.

Third-party libraries are frozen at build time and travel inside each release — a new app version
carries the new library versions. There is no separate library updater by design.

---

## License

Goel° is © 2026 Vinit Kumar Goel — see **[LICENSE](LICENSE)**.

The app bundles several third-party open-source components (libtorrent, OpenSSL, libssh2, Boost, GRDB,
Sparkle, and optionally yt-dlp), each under its own permissive license. Full attributions and license
texts are in **[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**, which also ships inside the app.

> You are responsible for ensuring your use of this software — including what you download — complies
> with applicable law and the terms of service of the sites and networks you use.
</content>
