# Getting started with Goel°

Goel° is a native macOS download manager that puts HTTP, FTP/FTPS, SFTP, BitTorrent and
HLS into one queue. It also runs headless on Linux, where the built-in web portal is the
whole interface.

**Licensing in one line:** free for personal use, paid licence for organisations. See
[commercial licensing](https://goel.vinitk.dev/commercial) if you are installing this at
work.

---

## Install (macOS)

Requires macOS 14 (Sonoma) or later, Apple Silicon.

1. Download the latest `.dmg` from
   [Releases](https://github.com/vinitkumargoel/goel/releases).
2. Drag `Goel°.app` into `/Applications`.
3. Launch it. Everything the app needs — libtorrent, libssh2, OpenSSL — is inside the
   bundle, so there is no Homebrew step and no separate runtime to install.

If macOS refuses the first launch, right-click the app and choose **Open**, then confirm.
That is Gatekeeper's standard first-run prompt.

### Build from source

```sh
git clone https://github.com/vinitkumargoel/goel.git
cd goel
swift build -c release
```

The Swift 6.3 toolchain is required; the package targets `swift-tools-version:5.10`.
macOS builds link against Homebrew's libtorrent-rasterbar, libssh2 and OpenSSL 3 — set
`GOEL_BREW_PREFIX` if your Homebrew is not at `/opt/homebrew`.

Run the test suite with `swift test`.

---

## Your first download

1. Copy a URL, a magnet link, or the path to a `.torrent` file.
2. Press **Add** in the toolbar (or paste directly into the window — Goel° reads the
   clipboard when the Add sheet opens).
3. Pick a destination folder and a priority, then confirm.

The queue takes it from there. Goel° works out the protocol from the source itself, so
an HTTPS link, a magnet URI, an `sftp://` path and an `.m3u8` playlist all go into the
same list and are managed the same way.

### What the columns mean

| Column | Meaning |
|---|---|
| **#** | Position in the queue |
| **Name** | Filename, with a progress bar underneath |
| **Proto** | HTTP, FTP, SFTP, BT or HLS — detected from the source |
| **Size** | Total bytes, once known (a magnet shows `—` until metadata arrives) |
| **Status** | Queued, Downloading, Verifying, Paused, Seeding, Completed, Failed |
| **Speed** | Current transfer rate |
| **ETA** | Estimated time remaining |

---

## Protocols

| Protocol | Notes |
|---|---|
| **HTTP / HTTPS** | Multi-connection segmented downloading, resume across restarts |
| **FTP / FTPS** | Explicit and implicit TLS |
| **SFTP** | Password or SSH key auth; keys and passwords stored in the macOS Keychain |
| **BitTorrent** | Magnets and `.torrent` files, per-file priorities, sequential mode, DHT |
| **HLS** | `.m3u8` playlists, including AES-128 encrypted segments |

---

## Credentials

Anything secret — site logins, FTP and SFTP passwords, SSH key passphrases, the web
portal password — is stored in the **macOS Keychain**, not in a config file. Goel° asks
the Keychain for them at the moment of use.

If macOS shows a Keychain prompt on first connection, that is the app requesting its own
stored item. Choosing **Always Allow** stops the prompt recurring.

---

## Remote access (Goel° Web)

Goel° can serve a small control portal from your own machine so you can manage the queue
from a phone or another computer.

1. **Settings → Web Access**.
2. Set a username and password, or copy the generated access token.
3. Enable the server and note the address.

The portal is served by your Mac. Nothing is relayed through a third-party server, and no
account is created anywhere. Two things worth knowing:

- **Bind to loopback unless you mean it.** Exposing the portal to a whole network, or to
  the internet, means anyone who reaches it can add downloads to your machine.
- **Read-only mode** (Settings → Web Access) serves the queue view and media streaming
  but refuses every state change. It is the right setting if you only want to watch.

For scripting the portal, see [remote-api.md](remote-api.md).

---

## Headless on Linux

`GoelDaemon` is the same engine with no GUI — the web portal is the interface.

```sh
swift build -c release --product GoelDaemon
./.build/release/GoelDaemon
```

Linux builds swap in swift-crypto for CryptoKit and SwiftNIO for Network.framework, and
link against the distro's own libtorrent-rasterbar, libssh2 and libcurl. GRDB needs a
SQLite built with `SQLITE_ENABLE_SNAPSHOT`; point `GOEL_SQLITE_DIR` at one if your
distro's stock `libsqlite3` does not have it.

---

## Updates

macOS builds check for new releases through Sparkle. This is the only outbound connection
Goel° makes that you did not ask for, and you can turn it off in **Settings → Updates**.
With it off, the app makes no network connection except the transfers you start.

---

## Privacy

There is no telemetry, no analytics, no crash reporting and no usage tracking. Your
queue, history, settings and credentials never leave your machine. This is not a setting
you have to find — it is the absence of the code that would do it, and you can confirm
that in the source.

---

## Next

- [FAQ](faq.md)
- [Troubleshooting](troubleshooting.md)
- [Remote JSON API](remote-api.md)
- [Compliance pack](compliance/) — SBOM, security questionnaire, support SLA
