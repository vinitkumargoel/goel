# GoelDownloader — Product Direction

> **Name:** GoelDownloader
> **What:** A native macOS download manager that unifies direct downloads (HTTP/HTTPS) and BitTorrent in one queue and one interface, with Free Download Manager-level configurability.
> **Inspiration:** Free Download Manager, rebuilt natively in Swift.

This is a **product-direction brief** — the *what* and the *why*. It deliberately
contains no code; APIs and engineering detail belong in a separate technical design
doc once this direction is agreed.

---

## 1. Mission

A fast, native macOS app that downloads files over HTTP/HTTPS **and** BitTorrent
from a single, unified queue — and is configurable enough that a current FDM user
can switch to it, set it up the way they like, and never look back.

## 2. Scope

**In scope (v1)**
- Direct downloads (HTTP/HTTPS) with multi-connection (segmented) speedups.
- Torrents via `.torrent` files and magnet links, including per-file selection.
- One unified queue: pause / resume / cancel, priorities, concurrency limits.
- Batch adding: paste multiple URLs from clipboard or from a text file.
- Persistent state — downloads and resume position survive quit and relaunch.
- Switchable traffic-limit profiles (Low / Medium / High) covering up/down speed,
  connection counts, concurrency, and seeding ratio.
- Default-folder rules (auto / by file type / by source URL / fixed).
- Notifications and power-management rules (sleep, battery).
- Watch-folder for new `.torrent` files; auto-shutdown when downloads finish.
- Export / import of the download list and settings; periodic backup.
- Native interface, menu-bar item, completion notifications.

**Deferred (later phases — acknowledged, not forgotten)**
- **Browser integration / extension capture** (you noted this — parked for Phase 4).
- **Remote access / web UI** ("connect to a remote instance").
- **Add-ons / plugin system.**
- **Antivirus integration** (run an external scanner on finished files) — optional,
  low priority on macOS.
- **Time-of-day scheduling** (start downloads at a set time). Note: auto-shutdown
  on completion and power rules ship earlier; only calendar scheduling is deferred.
- **FTP** — cut (Apple's FTP support is legacy; real FTP needs libcurl).

**Explicitly not building** (FDM's business model, not features)
- "Show special offers," "Support the project," "Join the Mosaic," bug-report links,
  and the legacy "UI style: Old/New" toggle.

## 3. Guiding principles

- **One queue, one interface.** The *user interface* never special-cases
  torrent-vs-file. (The *scheduler* legitimately must — a seeding torrent still uses
  a connection slot and upload bandwidth while a finished direct download uses
  nothing. The rule applies to the UI and the public task model, not internal
  accounting.)
- **Everything configurable from Settings.** If FDM exposes a knob for it, we expose
  it too (minus the promo items above). The user should be able to tune behavior and
  forget about it.
- **HTTP first, torrents second — but prove the shared model against both before
  freezing it.**
- **Native and efficient** over cross-platform convenience.

## 4. The unified task model (the most important product decision)

The shared "download task" both engines present must represent all of the following
from day one — these are requirements for the model, expressed in the technical doc:

- **Upload as well as download** — bytes up/down, up/down speed, and ratio. Required
  for the torrent UI and to honor the upload cap and seeding ratios.
- **Multi-file transfers** — a torrent is often many files with per-file selection
  and priority (the **Files** tab). A plain HTTP download is just the one-file case.
- **A pre-metadata state** — for a magnet link, name/destination/size are unknown
  until metadata arrives from peers ("Requesting info" in FDM).
- **Persistable status with a concrete failure reason** — so a failed cause survives
  relaunch and drives the UI. A distinct *seeding* state is required.
- **Live, observable progress** — the UI subscribes to a stream rather than polling.

## 5. Application surface & interaction

**Download list (main window).** Sortable columns: number, Name, Size, Status,
Download speed, Upload speed, Added (date). Each row shows a pause/resume state icon
and a context menu (resume, pause, remove, remove with data, open folder, copy
source, set priority). The list is filterable ("All files" → by type and by status:
completed / active / paused / seeding) and searchable.

**Top toolbar.** Bulk-select control (all / none / completed), a sort control, a
filter control, an **Add download** button, a search field, and a toggle to show/hide
the detail panel.

**Adding downloads.** Enter or paste a URL or magnet and pick a destination; or
drag-and-drop a URL or `.torrent` file anywhere onto the window (a visible drop
target). Batch add via paste-from-clipboard and paste-from-file.

**Detail panel (tabs, mirroring FDM).**
- **General** — name, save path (with copy button), downloaded, uploaded + ratio,
  added date, upload speed, priority, and the source URL/magnet.
- **Details** — full metadata (info hash, piece count/size, tracker list, MIME, etc.).
- **Progress** — visual per-segment (HTTP) or per-piece (torrent) progress.
- **Files** — the multi-file list with per-file selection and priority.
- **Connections** — live peer/segment connections with per-connection stats.

**Bottom status bar.** A global speed-limit toggle (the "snail" — Unlimited vs the
active profile), live aggregate down/up speeds, and the active traffic-limit profile
selector (Low / Medium / High).

**Main menu.** Paste URLs from clipboard; paste URLs from file; start all seeding /
stop all seeding; Export/Import; Preferences; Auto shutdown; Check for updates;
About; Quit. (Add-ons and "connect to remote instance" appear here once those
deferred features land.)

## 6. Settings & preferences (full configurability)

All settings persist (see Persistence decision) and feed the scheduler and engines.
Panels mirror FDM, minus the deferred/omitted items.

**General**
- Theme: System / Light / Dark.
- Language (English to start; structured for localization).
- Launch at login, optionally minimized.
- Default download folder: choose automatically, optionally suggesting folders by
  file type or by source URL; or a fixed folder. Folder tokens/macros (date, type)
  can come later.

**Network**
- Proxy configuration; connection timeout; retry count and interval; custom
  user-agent; cookie/authentication handling for protected downloads (useful even
  with browser integration deferred).

**Traffic Limits** (the profile system — a key feature)
- Three switchable profiles — **Low / Medium / High** — each with: max download
  speed, max upload speed, max connections (global), max connections per server, max
  simultaneous downloads, and stop-seeding-at-ratio.
- Global knobs: max concurrent metadata-resolution downloads ("querying info"), and
  "enable additional connections to optimize speed."
- The active profile is switchable from the status bar; the snail toggles Unlimited
  vs the active profile.

**BitTorrent**
- Make GoelDownloader the default torrent client (own `magnet:` and `.torrent`).
- Automatically delete the `.torrent` file once the download finishes.
- Monitor a folder for new `.torrent` files, optionally starting without confirmation.
- Privacy/protocol: encryption mode (Prefer / Require / Disable), enable DHT, enable
  PeX, enable Local Peer Discovery.
- Advanced: enable uTP. (These map directly onto torrent-engine session settings.)

**Advanced**
- Notifications: on added / completed / failed downloads; only when the app is
  inactive; optional sounds — via macOS Notification Center.
- Power management: prevent sleep during active (and scheduled) downloads; allow
  sleep if downloads can resume later; allow sleep while seeding; pause downloads
  below a battery threshold; don't seed on battery.
- Backup: periodically back up the download list (configurable interval).

**Antivirus** (optional, deferred-ish)
- Select a scanner or configure manually with an executable path and an argument
  template (e.g. `%path%`) to scan finished files. Low priority on macOS.

**Browser Integration** (deferred) — panel reserved; the extension comes in Phase 4.

**Remote Access** (deferred) — panel reserved; web UI / remote control comes later.

## 7. Architecture (conceptual)

Four layers. The interface sits on a download manager / scheduler that owns the
queue, concurrency limits, priorities, traffic-profile enforcement, and one global
bandwidth ceiling. Beneath it, a persistence layer stores task metadata, resume
blobs, settings, and error/seeding state. At the bottom, two interchangeable engines
— HTTP and torrent — present the same unified task model upward. Torrent-library
symbols stay sealed inside the torrent engine.

## 8. Engine direction

- **HTTP engine.** Segmented range requests, with edge cases treated as first-class:
  detect range support and fall back to a single connection; disable segmentation
  when no content length is given; validate the remote file on resume so an upstream
  change can't corrupt a stitched download. Check free disk space and preallocate.
- **Torrent engine.** *Production:* libtorrent-rasterbar behind a thin macOS adapter
  (the XITRIX/LibTorrent-Swift wrapper is a useful reference but is iOS-oriented —
  budget adaptation time). *Validation:* swift-torrent (pure Swift, macOS 14+, no
  C/C++) is the cheap way to de-risk the unified model early; maturity unproven.
- **Bandwidth.** The torrent library rate-limits itself; the HTTP side needs a shared
  throttle, and the two must be coordinated under one global ceiling. Real design
  work, driven by the active traffic profile.

## 9. Roadmap

**Phase 0 — De-risk the model.** Spike the torrent engine's status/event surface and
validate the unified task model against *both* engines before locking it.

**Phase 1 — Foundations.** Unified task model; HTTP engine (single then segmented,
with resume); queue/manager; native list + detail UI with live progress; a minimal
Settings scaffold (theme, default folder, concurrency). No torrent code yet.

**Phase 2 — State, control & settings.** Persistence and relaunch restore; the
Traffic-Limits profile system + global bandwidth caps + status-bar profile switcher;
notifications; power management; batch paste-URL adding; export/import and backup;
menu-bar item.

**Phase 3 — Torrents.** Torrent engine behind the same model; `.torrent`/magnet
support; the full BitTorrent settings panel (encryption, DHT, PeX, LPD, uTP,
watch-folder, auto-delete `.torrent`, make-default-client); per-file selection;
seeding controls and ratio limits; the Connections tab.

**Phase 4 — Reach & integration.** Browser integration, remote access/web UI,
add-ons, time-of-day scheduling, and optional antivirus integration.

## 10. macOS constraints

- **Distribution drives entitlements — decided:** ship **direct, notarized, outside
  the Mac App Store**, because torrenting's listening ports and user-folder writes
  fight the App Sandbox.
- Security-scoped bookmarks for folder access across launches; network entitlements;
  code signing + notarization.

## 11. Decisions (resolved)

- **Name:** GoelDownloader.
- **Distribution:** direct notarized, non–App Store.
- **Persistence:** GRDB — engine-driven background writes plus resume blobs, settings,
  and serializable error states.
- **Connection / concurrency model:** profile-based (Low / Medium / High) with global
  and per-server connection caps and a simultaneous-download limit, matching FDM;
  Medium is the sensible default. (Supersedes the earlier "4–8 segments" note.)
- **Torrent engine:** prototype on swift-torrent to validate the model; plan
  libtorrent (adapted macOS shim) for production.
- **FTP:** cut from v1.
- **Omitted by design:** FDM's promo/monetization items and the legacy UI-style toggle.

## 12. Smaller items to honor

- Disk-space check and file preallocation before a download starts.
- Duplicate-URL and duplicate-torrent detection.
- Integrity: torrents self-verify via piece hashes; HTTP downloads have none — offer
  optional checksum verification.

## 13. Open questions

- Confirm the multi-file model: one task as a container of selectable files
  (recommended) vs one task per file.
- The mechanism for coordinating one global bandwidth ceiling across two engines.
- Is antivirus integration worth building on macOS, or drop it entirely?
- Should the `.torrent` watch-folder default on or off?
- Final production engine call (swift-torrent vs adapted libtorrent) after Phase 0.
