# Changelog

All notable changes to Goel° are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **`goel <url>` downloads and waits — the CLI is now a curl replacement.** Give `goel` a
  URL (http/https, ftp/ftps, sftp, magnet, `.torrent`, `.m3u8`) with no subcommand and it
  queues the download on the daemon, follows it with a live progress line, and exits when
  the file is on disk, printing the saved path. Ctrl-C detaches rather than cancels — the
  download continues server-side. `--detach` queues asynchronously (as `goel add` always
  has; it gains `--wait` for the opposite), `--timeout N` bounds the wait, and the exit
  codes are a documented contract: 0 saved, 1 error, 2 usage, 3 refused/failed, 4 timeout,
  130 detached. Full reference: **docs/cli.md**.
- **`--json` on `goel add`, `goel list`, `goel status`, and wait mode** — stable
  machine-readable output on stdout (diagnostics stay on stderr), so scripts and AI agents
  can drive the whole queue without scraping tables. Wait mode always emits an array of
  final task details, one per URL, including `savePath`.
- **`POST /api/add` now returns `ids`** — one task UUID per accepted source, in request
  order (a deduplicated source returns the existing task's ID). This is what lets a client
  queue a download and then follow it; documented in docs/remote-api.md.
- **The CLI and daemon now run anywhere, not just on the Linux install.** `GoelDaemon`
  builds and runs on macOS; both it and `goel` resolve configuration from `$GOEL_CONFIG`,
  then `/etc/goel/config`, then `~/.config/goel/config`, with `GOEL_PORT`/`GOEL_TOKEN`
  environment variables overriding the file (`GOEL_TOKEN` alone is enough — no file
  needed). `goel config set` creates the user-level file (0600) without root; `goel
  doctor` skips the Linux-installer checks on a portable install instead of failing them;
  `goel web` opens the portal in the browser.
- **The download queue now selects the way every other Mac list does.** ⇧-click selects the
  run from the last-clicked row to the clicked one (and shrinks it again — the anchor stays
  where it was), ⇧⌘-click adds that run to the current selection, ⌘-click still toggles a
  single row, ⌘A selects everything the list is showing, ⇧⌘A deselects, escape clears, and
  ⇧ with ↑/↓ (or home/end) extends the selection from the keyboard. Select All and Deselect
  All are in the Edit menu; ⌘A inside the search field still selects its text.
- **Right-clicking inside a multi-row selection commands the whole selection.** The menu
  switches to selection-wide items with counts — Resume/Pause/Retry *n* Selected, Copy *n*
  Source Links, Rename *n* Selected…, Remove *n* from List, Remove *n* with Data (one
  confirmation for the batch) — instead of quietly acting on the single row under the
  pointer. Per-row items (tags, note, Quick Look, per-task limits) stay on the single-row
  menu.

### Fixed

- **First writes under `/private/…` on macOS were misread as path-traversal attempts.**
  `resolvingSymlinksInPath` strips the `/private` prefix from a path that exists but not
  from one about to be created, so the containment guard compared a stripped directory
  against an unstripped file path and refused the download. The guard now retries with the
  prefix stripped from the nonexistent side only — which cannot admit a real escape, since
  such a path still begins with the configured save directory.
- **Servers that transparently gzip responses broke downloads.** URLSession negotiates
  compression by default, making `Content-Length` (compressed) disagree with the bytes
  written (decompressed) — sizes, segment ranges, and the completeness check all went
  wrong ("wrote 3808 of 1701 bytes"). Every engine request now sends
  `Accept-Encoding: identity`: a downloader stores payload bytes verbatim.
- **`goel add` refused wholesale (SSRF guard, unwritable folder, read-only mode) now
  reports the portal's actual reason** instead of a generic 403 guess, and exits 3 — the
  documented "download did not happen" code — rather than 1.
- **`goel config get` now honours environment overrides** (`GOEL_PORT=9999 goel config
  get port` prints `9999`), matching the precedence every other command — and `config
  list`'s own `(from $ENV)` marker — already applied. Scripts introspecting the
  effective value no longer get an answer that contradicts what `goel add` connects to.
- **The same URL given twice in one `goel add --wait` no longer reports twice.** The
  portal deduplicates the download but echoes the same task ID once per source; the
  report now collapses to one `Saved` line / one JSON entry per actual task.
- **Re-adding a source now makes the download happen again when the payload isn't on
  disk.** Adding a URL that had previously *failed* retries it (previously it silently
  returned the dead row, and `goel <url> --wait` exited 3 without a single new byte
  attempted). Adding a URL whose completed file was since *deleted* drops the stale row
  and downloads afresh — closing the window where deleting a file and immediately
  re-requesting it (an agent's download-consume-delete loop) returned `Saved` for a
  file that wasn't there. A completed task whose file still exists stays idempotent:
  same row, `Saved` immediately.

### Security

- **Server-chosen text is stripped of terminal escapes before printing.** Filenames come
  from `Content-Disposition`, magnet `dn=`, and torrent metadata — a hostile server could
  embed ANSI/OSC sequences and retitle the window or poison the clipboard when `goel`
  prints the name. Control characters are now removed from names, error strings, and
  paths in all human-readable output (JSON output already escaped them).
- **`goel web` no longer passes the tokened URL as a process argument** to
  `open`/`xdg-open`, where any local user could read it with `ps` and exec-audit tooling
  would record it. The browser now opens a private redirect file (mode 0600) instead.
- **Config files reached via the environment are no longer trusted blindly.** The daemon
  ignores (loudly) a config file that is neither owned by its own user nor root, or that
  is world-writable; and `goel config set`/`token rotate` running as root refuse to write
  to a non-system path whose directory another user controls. Both close the
  `sudo -E`-style hole where an attacker-controlled `$GOEL_CONFIG`/`$XDG_CONFIG_HOME`
  could feed a privileged process a token, password, or LAN exposure it chose.

---

## [1.0.4] — 2026-07-27

**This release also carries `1.0.3` and `1.0.2` below, neither of which was ever published.**
No `v1.0.2` or `v1.0.3` tag was pushed and no release was cut for either, so the last thing
anyone actually received is `v1.0.1`. Upgrading from it means taking all three sections.

### Changed

- **The web portal is now React + TypeScript.** It was a vanilla-JS single-page app living
  inside Swift string literals — 39 KB of hand-minified code with single-letter variables and
  a 2099-character line, no build step, no types, and `\` and `#` as escaping hazards because
  it sat inside `#"""…"""#`. It is now a real front end in `/portal`, compiled by Vite into
  `PortalBundle.swift` and served from `/assets/portal-<hash>.js`, with the generated file
  committed so `swift build` still works on a machine with no Node installed and CI failing on
  drift. Nothing about the portal's behaviour changes for you; what changes is that the next
  feature in it can be written.

  Both products still share one codebase: the portal lives in `GoelCore`, and the macOS app
  and the Linux daemon serve the identical bundle through the same router. Assets are
  content-addressed and cached for a year; the four themes now have exactly one definition
  rather than a Swift copy and a JavaScript copy that could drift apart.

### Added

- **The portal's Add dialog browses for the save folder instead of asking you to type it.** It
  wanted an absolute server path in a free-text field, and a typo only surfaced at submit
  time — you found out after composing the whole request, with nothing to correct it against.
  There is now a Browse button, a folder tree, shortcuts to Downloads, Home, mounted volumes
  and the filesystem root, and a "New folder" button. Two routes back it, `GET /api/folders`
  and `POST /api/folder`, documented in `docs/remote-api.md`.

  Web only. The macOS app opens a real `NSOpenPanel`, which understands sandbox scope and
  mounted volumes in ways a remote browser cannot; nothing there changes.

### Changed — read this one before upgrading

- **A portal session can now save a download anywhere the server's user can write, not only
  inside the downloads folder.** The picker had a hard ceiling at
  `settings.defaultSaveDirectory` and could not climb above it, which meant the portal could
  not put a file anywhere you would reasonably want it. The boundary is now the operating
  system's own: every folder is browsable if that user can list it and selectable if that
  user can write to it, and the picker greys out the rest using the filesystem's answers
  rather than a rule of its own.

  **This widens what an authenticated portal session can reach.** On macOS the app runs as
  you, so a session can now write into auto-run locations such as `~/Library/LaunchAgents`;
  the portal password is what stands in front of that, which is a reason to set a strong one
  and to think twice before exposing the portal beyond your LAN. On Linux the daemon runs as
  the unprivileged `goel` system user, so its reach is whatever you granted that account —
  which is the intended way to bound this.

### Fixed

- **The SFTP browser no longer forgets where you were.** Each server now keeps its
  last-known-good directory across sessions, held separately from the connection's configured
  start folder so browsing somewhere else does not quietly rewrite the setting.

- **An SFTP transfer will now show you where it is going.** Clicking a transfer's name opens
  that remote folder in the browser; before, the destination path was not reachable from the
  transfer at all.

- **Numeric settings fields no longer insert a thousands separator.** The port field showed
  `8,899` for port 8899 — wrong for a port, which is an identifier rather than a quantity, and
  unwanted in the other numeric rows too, since those are values you type back and a separator
  you did not type is at best noise.

- **The portal's task list dropped a column header onto nothing below 920px.** The header
  rendered four labels into a three-column grid while the rows rendered three cells, so
  "Speed" wrapped onto a line of its own.

- **The portal's History "folder" column repeated the file name beside it** — the one thing
  that column exists not to do. It took the last path component, but the stored path is the
  directory *plus* the file name.

- **Unticking every network interface in the portal's settings selected all of them.** An
  empty list means "every eligible adapter" to the server, so the exact opposite of the
  request was saved and came back all-ticked on reload. Saving with nothing ticked is now
  refused in the dialog.

- **The portal codegen could have silently rewritten `\#n` into a newline.** It guarded only
  interpolation when choosing a raw-string delimiter; a minified regex containing `\#n` is
  legal and would have been corrupted without failing the build.

---

## [1.0.3] — prepared 2026-07-27, never published

No `v1.0.3` tag was pushed and no release was cut, so nothing below reached anyone as `1.0.3`.
It is kept as its own section because the work is distinct and was written up at the time; it
ships in `1.0.4` above. The date is when it was prepared, not a release date.

**This section also carries everything listed under `1.0.2` below, which was prepared but
never published** — no `v1.0.2` tag was ever pushed and no release was ever cut, so the
licence change and the deployment-target fix reach users here for the first time. Upgrading
from `v1.0.1` means taking both.

### Added

- **Linux installs in one line, and has a `goel` command.**

  ```sh
  curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh
  ```

  Before this, "installing on Linux" meant downloading a tarball, working out the runtime
  packages for your distribution by hand, and running `./run.sh` from a shell — with no service,
  no unattended start, and no way to configure anything except environment variables you had to
  remember to re-set. The installer now resolves the dependencies for the distribution it finds
  itself on, verifies the download against its published SHA-256, creates an unprivileged `goel`
  system user, installs a hardened systemd unit, generates a portal password and prints it once.
  Re-running it upgrades in place and keeps your configuration, queue and downloads.

  The **`goel`** command manages the result: `status`, `start`/`stop`/`restart`,
  `enable`/`disable`, `logs -f`, `config` (get/set/unset/sync), `url`, `token show|rotate`,
  `add`, `list`, `pause`/`resume`/`retry`/`rm`, `doctor`, `uninstall [--purge]`. It drives the
  daemon's own JSON API for queue operations, so there is one implementation of each behaviour
  rather than two.

  `goel doctor` is the notable one: it checks the shared-library closure, the config file's
  permissions, the service state *and* whether it is enabled at boot, whether the daemon can
  actually write to its download folder **as the `goel` user** rather than as root, whether the
  port is held by something else, and whether the portal answers. Those are precisely the
  failures that are otherwise silent.

- **Per-download choice of network interface, configurable from the web.** A machine with more
  than one uplink can now be told what to do with them per download, not just globally: follow
  the server default, split one download across several interfaces, or pin it to exactly one.
  The Add dialog in the portal offers the choice whenever two or more interfaces are eligible,
  `goel add --net single:eth0` does it from a shell, and `POST /api/add` takes a `network` field.
  A pinned download egresses its interface even when aggregation is switched off globally, and
  even when the server does not support ranges — that last case previously fell back to
  `URLSession`, which cannot bind a socket to a device, so the pin was silently ignored.

  Splitting is worth measuring before trusting: two adapters behind the *same* router share one
  pipe, and on the machine this was developed against, the two together ran at roughly half the
  speed of the faster one alone. The portal and `goel adapters` both say so.

  The policy itself is configurable three ways, and they compose rather than fight:
  `GOEL_AGGREGATION`, `GOEL_AGGREGATION_ADAPTERS` and `GOEL_AGGREGATION_STREAMS` in
  `/etc/goel/config` (via `goel config set aggregation …`), the new `GET`/`POST /api/network`
  routes, and a Settings section in the portal. Leaving the environment variables unset — the
  default — means "whatever was last saved", so a change made in the portal survives a restart;
  setting one makes the file authoritative, and the portal then *says* that a change made there
  is temporary rather than pretending otherwise.

  Proxy and VPN policy are hard exclusions here, not preferences: binding a socket to an
  interface bypasses both, so when a proxy is configured or a VPN holds the default route, there
  is nothing to pin to and the UI offers nothing.

- **`goel adapters`** lists what the machine actually has — interface, address, whether it can be
  bound, and whether the current policy would use it — plus the aggregation state and, when
  applicable, the concrete reason it is not splitting.

- **One Linux tarball now works across distribution releases.** libtorrent and Boost are bundled
  alongside the Swift runtime, because their SONAMEs encode upstream versions that change between
  releases — Ubuntu 24.04 has `libtorrent-rasterbar.so.2.0` and 26.04 has `.so.2.1`, and Boost
  goes 1.83 → 1.88 — so a tarball built on one could not start on the other. OpenSSL, libcurl and
  libssh2 are deliberately *not* bundled: their SONAMEs are stable, and freezing someone else's
  TLS stack into a release is worse than using the one the operator's distribution is patching.

- **[docs/linux.md](docs/linux.md)** — the full Linux guide: installer options, every
  configuration key, how writable paths work under `ProtectSystem=strict` and why a download can
  otherwise fail on write, upgrading, uninstalling, running without systemd, non-Debian
  distributions, and building from source. Several error messages already pointed at this file.

- **CI now covers Linux.** The daemon and CLI are built and tested on Ubuntu 24.04, the tarball is
  packaged and its contents asserted, and then it is *installed on a newer Ubuntu* — the
  cross-release case that a developer's own machine never exercises and that the shipped tarball
  would have failed. The install job exercises the CLI end to end and asserts that
  `uninstall --purge` leaves nothing behind.

- **Goel° Capture now has an icon.** The extension shipped with no `icons` and no
  `action.default_icon` at all, so Chromium browsers drew a generic grey initial and Safari's
  extension list showed a blank entry — for a toolbar button whose install instructions say
  "click the toolbar button". A 16/32/48/128 px set from the app's own mark is now bundled.
- **The extension reports what happened.** A hand-off used to be entirely silent in both
  directions: on success nothing changed (the app may be closed or on another Space), and on
  failure nothing changed either, which is indistinguishable from a broken extension. The
  most common failure by far — the native-messaging helper not being installed yet — now
  shows a red `!` on the toolbar button reading *"can't reach the app. Open Goel° ▸ Settings ▸
  Browser and click Install Helper."* A refused URL, a cookie-less send and a successful send
  each get their own badge and tooltip. Nothing uses system notifications, because that would
  mean requesting a `notifications` permission purely to report errors.
- **[docs/browser-extension.md](docs/browser-extension.md)** — the extension had no
  documentation beyond three bullets in the FAQ. The new guide covers install per browser
  (including which browsers want the *folder* and which want `manifest.json`), the messaging
  helper and the two ways it silently does nothing, a capability matrix, exactly what happens
  to forwarded cookies, troubleshooting, removal, and how to hack on it.
- Troubleshooting now has a browser-extension section; it previously had none.

### Fixed

- **The Linux daemon saw zero network interfaces, and said so as "none found".** The systemd
  unit's `RestrictAddressFamilies=` listed `AF_UNIX AF_INET AF_INET6` but not `AF_NETLINK`,
  which is what glibc's `getifaddrs()` opens — so under systemd every adapter and
  aggregation feature reported an empty list while working perfectly when run by hand. A
  failed enumeration now logs the errno instead of returning an empty array in silence.
- **Saving any setting could kill the Linux daemon minutes later.** Reconfiguring the HTTP
  engine replaced its `URLSession` without invalidating the old one, and
  swift-corelibs-foundation keeps a retain cycle through the session's `_MultiHandle` until
  it is invalidated — collecting one tripped the runtime's "deallocated with non-zero retain
  count" trap and took the process down with `SIGILL`, on an unrelated thread, long after
  the save. Observed in production testing; the outgoing session is now retired first.
- **Upgrading over a running daemon kept executing the old binary.** The installer used
  `systemctl enable --now`, which starts a stopped service but leaves a running one untouched —
  so a reinstall replaced `/opt/goel` on disk and none of it ran until the next reboot. It now
  restarts explicitly. (Found by installing a fix and watching the bug it fixed reoccur.)
- **A download bound to an interface reported "Could not connect to server" and nothing
  else.** An interface can hold an address and still have no working upstream — the ordinary
  state of a second NIC that has not been given policy routing. Transport failures now name
  the interface they were bound to.
- **`POST /api/network` silently ignored `streamsPerAdapter`.** The reply spells the field
  `streamsPerAdapter` and the request accepted only `streams`, so posting back the object
  `GET` had just returned dropped the value *and* skipped its 1–8 range check. Both
  spellings are accepted now.
- **Tailscale and container interfaces were offered as download uplinks on Linux.** The
  tunnel filter matched `tun*`/`utun*`/`wg*`, which Tailscale, ZeroTier, Nebula and several
  commercial VPNs do not use — `tailscale0` has an address and looked like an ordinary
  adapter, so aggregation would happily route downloads through the tailnet. The virtual
  filter has likewise grown `virbr`, `cni`, `flannel`, `cali`, `kube` and `dummy`, which a
  box running Docker or libvirt has by the dozen and none of which reaches the internet.
- **GoelCore did not compile on Linux at all.** Two constants that Glibc types differently from
  Darwin — `net/if.h`'s interface flags (`Int`, not `Int32`) and `SOCK_STREAM` (`__socket_type`,
  not `Int32`) — broke the build in July's network-aggregation work and stayed broken because
  nothing built Linux. Normalised in `LinuxCompat.swift`, and CI now builds and tests Linux.
- **The Linux daemon lost every translation.** SwiftPM names its generated resource bundle
  `.resources` on Linux and `.bundle` on Darwin; the resolver only knew the second, and the
  packager never shipped the bundle at all. Both fixed — German resolves on Linux now. This was
  invisible because the lookup keys *are* the English text, so it read as "not localized yet".
- **A tarball built on Ubuntu 24.04 could not start on 26.04.** `libFoundationXML.so` needs
  `libxml2.so.2`, which is `libxml2.so.16` on 26.04 with no `libxml2` package at all — and
  vendoring it by name would then have failed one hop later on ICU. The packager now walks
  direct `DT_NEEDED` edges transitively and bundles everything whose SONAME is not known
  stable, then verifies the result is self-contained before writing the tarball.
- **Linux test coverage was zero.** `GoelCoreTests` and `GoelCLITests` were gated to macOS
  despite not depending on the app; 680 of them now run on Linux, with the handful that need
  `Network.framework`, `AVFoundation`, `CommonCrypto` or macOS release tooling guarded.
- **`testPauseStopsProgress` raced the transfer it was pausing.** It slept a fixed 200 ms before
  pausing, which a fast machine's parallel range requests finish inside — the test then failed
  for having completed. It now pauses on observed progress instead.
- **`goel list` hid why a download failed and that anything had finished.** The failure reason
  was already in the API response and never printed, and completed downloads are filtered out
  with no indication, so a download that just finished looked like it had vanished.
- **`goel doctor` said nothing about ffmpeg**, whose absence fails HLS downloads only —
  now a warning rather than silence.
- **`goel uninstall --purge` claimed to delete downloads it does not touch.** A configured
  `save-dir` outside `/var/lib/goel` is deliberately left alone; it now says so.
- **`/Applications/Goel°.app` crashed on launch.** SwiftPM's generated `Bundle.module` accessor
  traps with `fatalError` when it cannot find its resource bundle, and it looked in two places
  neither of which existed in an installed app — so the app died before `main()` with
  `could not load resource bundle`. Resource lookup now searches the places the bundle actually
  lands and degrades (untranslated strings, no notification icon) instead of trapping, and
  `Scripts/build_app.sh` fails the build if `Bundle.module` reappears in `Sources/` or if the
  resource bundles do not end up inside the app.
- **Re-running the Linux installer no longer breaks a customised install.** The installer derived
  the download folder from `$GOEL_SAVE_DIR` while keeping the existing `/etc/goel/config`, so an
  upgrade on a machine with a custom `save-dir` rewrote the writable-paths drop-in for the
  *default* path — and because the unit runs `ProtectSystem=strict`, the service then started
  perfectly and failed every download the moment it tried to write. The same overwrite silently
  dropped the watch folder and a relocated database. The drop-in now has exactly one writer:
  `goel config sync`, which reads the config file and therefore cannot disagree with it.
- **The Linux installer refuses a release it cannot verify.** Its own comment said an unchecksummed
  release was one it would "refuse to install silently", but the code warned on stderr — invisible
  in a `curl | sudo sh` session — and installed it anyway as root. It now stops, with
  `GOEL_INSECURE=1` as an explicit opt-out. `package_daemon.sh` generates the `.sha256`, and CI
  asserts it exists, because until now nothing produced one and so every install was unverified.
- **A download folder that is a symlink is now refused.** Both the installer and
  `goel config set save-dir` ran `chown -R` on the given path, and a recursive `chown` follows a
  symlink named on the command line. Since saving downloads under `/home` is ordinary and
  documented, an untrusted local user could pre-create `~/downloads` as a link to `/etc` and wait
  for an admin to point Goel° at it, handing the service account ownership of the target.
- **`goel config set db <path>` created a directory where the database file goes**, leaving SQLite
  unable to open it and the daemon dead on the next start with the cause nowhere in the journal.
  It now creates the *parent* directory.
- **A read-only `goel` command without `sudo` said Goel° was not installed.** `/etc/goel/config` is
  `0600` root-only by design, so the commonest mistake — forgetting `sudo` on `goel status` — hit
  a permission error that was reported as "does not look installed on this machine", complete with
  advice to reinstall. Unreadable and absent are now told apart.
- **`goel config` could leave the portal password world-readable and report success.** The
  temporary file was written and then `chmod`ed, with the result discarded — so a failed `chmod`
  renamed a readable file into place while the command printed a green "Set password". It is now
  created `0600` and verified before the rename.
- **`goel uninstall` printed "Removed." unconditionally.** Every teardown step is best-effort by
  design, but their results were all discarded, so a service that would not stop or a `goel` user
  that could not be deleted still produced a clean green success. Failures are now named.
- **A failed `chown` no longer reports a successful configuration change.** `goel config set
  save-dir` discarded the result, so the two lines it printed were "Set save-dir" and "Restarted"
  while the daemon was about to fail every download writing there.
- **Ctrl-C out of `goel logs -f` no longer reports an error.** Foundation gives the raw signal
  number for a signalled child, not the shell's `128+n`, so an ordinary Ctrl-C surfaced as
  `journalctl exited 2`.
- The systemd unit now clears its capability bounding set and sets `UMask=0027`, so downloads under
  `/home` on a shared machine are not group- and world-readable. `goel config` quotes paths in
  `ReadWritePaths=`, which is whitespace-separated — a folder with a space in its name silently
  became two paths that did not exist.
- `goel config set` refuses `/`, `/etc`, `/usr`, `/home` and the like. Every accepted path is
  created, recursively chowned to the service user and made writable to a process that parses
  untrusted torrent metadata; a leading `/` was the only check.
- `goel config unset save-dir|db|watch-dir` now refreshes the drop-in, and the CLI's idea of the
  daemon's default database and download paths now matches the daemon's actual defaults — they
  differed, so after an `unset` every authenticated command looked for the API token in a
  directory the daemon had never written to.
- **Safari no longer offers what it cannot do.** The "stay signed in" context-menu item and
  the cookie preference were shown in Safari, where the handler refuses cookies by design —
  so choosing them appeared to work and then quietly produced a login page. They are now
  omitted there, and if a cookie is ever dropped anyway the extension says so. The toolbar
  toggle likewise no longer badges `ON` in Safari, which has no `downloads` API and was
  capturing nothing; clicking it now explains that and points at the right-click menu.
- **The Safari handler's promise is now kept.** It has always answered `cookies: false` so
  that "the extension [could] tell the user that signed-in capture needs Chrome or Firefox" —
  but `background.js` discarded the reply entirely and told them nothing.
- **Firefox's minimum is 128, not 115.** The manifest requires `optional_host_permissions`,
  which Firefox only supports from 128, so the cookie grant could never succeed on 115–127
  while the manifest claimed those versions were fine.
- **`.gitignore` was swallowing the extension's `icons/` directory.** The macOS section used
  the widespread `Icon?` pattern for Finder's custom-folder-icon file (`Icon` + a carriage
  return), but `?` matches *any* single character, so `icons/` matched too and would have been
  left out of the repository without a word. Narrowed to `Icon[[:cntrl:]]`, which still
  catches `Icon\r` and no longer catches directories that merely start with "icon".
- The FAQ pointed at `Resources/BrowserExtension` for the bundled extension. It is at
  `Contents/MacOS/GoelDownloader_GoelApp.bundle/BrowserExtension` — where `Bundle.module`
  resolves, next to the executable.
- **Settings ▸ Browser Integration** now installs the helper *before* telling you to load the
  extension, says to restart the browser afterwards (host manifests are only read at browser
  startup — a step whose absence made a correct install look broken), notes that the helper
  skips browsers that have never been launched and must be re-run if the app moves, and states
  plainly what Safari cannot do.

---

## [1.0.2] — prepared 2026-07-25, never published

No `v1.0.2` tag was pushed and no release was cut, so nothing below ever reached anyone as
`1.0.2`. It is kept as its own section because the work is distinct and was written up at the
time; it ships in `1.0.4` above. The date is when it was prepared, not a release date.

First changes under the **PolyForm Noncommercial 1.0.0** licence. If you use Goel° at work,
read the licence section below before upgrading past `v1.0.1`.

### Changed

- **Licence changed from MIT to [PolyForm Noncommercial 1.0.0](LICENSE).** This is the
  headline change in this release and the one most likely to affect you.

  - Goel° remains **source-available and free forever for personal use** — individuals,
    hobby projects, private study, home media. Nothing about that changes and nothing
    about it expires.
  - **Commercial, business, government and managed-fleet use now requires a paid
    licence.** See [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) for who needs one and
    how to get one.
  - Charities, schools, universities, public research bodies and public safety, health
    and environmental organisations remain permitted under PolyForm itself, regardless of
    how they are funded.
  - **The application is unchanged by this.** There is no licence key, no activation, no
    trial clock, no feature gating, no nag screen, and no phone-home. Every user runs the
    identical binary with the identical capabilities. Compliance is honour-based on
    purpose — nothing in Goel° is able to lock a user out of their own downloads.
  - **The existing `v1.0.0` and `v1.0.1` tags remain MIT-licensed forever.** An MIT grant
    already made cannot be retroactively revoked, and this project is not going to pretend
    otherwise. Anyone who obtained those releases keeps their MIT rights to *those
    releases* in perpetuity, including for commercial use. The PolyForm licence applies to
    this release and everything after it.
  - Note on wording used throughout the project: Goel° is now **source-available**, not
    OSI "open source". A licence with a field-of-use restriction does not meet the Open
    Source Definition, and calling it open source anyway would be inaccurate.

- **README** — licence badge updated from MIT to PolyForm Noncommercial, and a
  "Licensing" section added near the top so the terms are visible before the install
  instructions rather than in a footnote at the bottom.
- **Website** — every "MIT licensed" and unqualified "open source" claim replaced with
  PolyForm Noncommercial / free-for-personal-use wording across the home page, terms,
  privacy and cookie pages. The terms page in particular told companies the software was
  free for any use, which is the highest-risk stale claim a buyer could have relied on.
  The privacy policy's "there are no contact forms" line was also corrected now that the
  enquiry form exists.
- **Sparkle updater** — the feed URL and EdDSA public key are read and validated from
  `Info.plist` (HTTPS and a host are required, the key must be non-empty) instead of being
  assumed present. A half-configured bundle is now treated exactly like an unconfigured
  one, so the updater stays a safe no-op on development builds rather than doing something
  half-right with an unverified feed.
- **`Scripts/build_app.sh`** — the release version is derived from an *exact* git tag
  (being 13 commits past `v1.0.1` does not make you `v1.0.1`), `CFBundleVersion` tracks the
  commit count so Sparkle's comparison stays monotonic, and the Sparkle plist injection is
  idempotent, all-or-nothing and HTTPS-enforced. The bundle now also carries
  `NSHumanReadableCopyright` and ships `LICENSE-COMMERCIAL.txt` and `TRADEMARK.txt`
  alongside the existing notices, so a copy of the `.app` on its own still states its terms.
- **Diagnostics logging** — the scheduler, persistence, credential-store and remote-server
  layers no longer write diagnostics straight to stderr. They go through the new logging
  facade, which routes to the local unified log on macOS and to stderr on Linux, and which
  redacts paths, hostnames and error text by default. Several of these lines previously
  printed a save path or a hostname in the clear into whatever captured stderr.

### Added

- **[LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md)** — who needs a commercial licence,
  who explicitly does not, how to request one, and what it includes: licence grant,
  invoice, support with a response target, update entitlement, and negotiated warranty
  and liability terms in place of PolyForm's "as is".
- **[TRADEMARK.md](TRADEMARK.md)** — the "Goel°" name, the g° mark, the app icon and the
  trade dress are reserved independently of the code licence. Forks may use the code
  under PolyForm but must pick their own name, icon and bundle identifier.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Developer Certificate of Origin sign-off is now
  required on every commit, alongside a short explicit inbound licence grant. Together
  these let contributed code be included in commercial licences; contributors keep their
  own copyright. Added now, while the project has one author, because retrofitting it
  across many contributors later ranges from expensive to impossible.
- **[SECURITY.md](SECURITY.md)** — private disclosure address, acknowledgement within 2
  business days, triage within 5, and a **vendored-dependency CVE policy**: because
  libtorrent, OpenSSL and libssh2 are frozen at build time inside the app bundle with no
  independent patch path, every dependency CVE requires a new Goel° release. Committed to
  a quarterly review of all bundled dependencies and a 7-day patched release for critical
  and high severity CVEs that affect Goel°.
- **CHANGELOG.md** — this file. Starting from [Unreleased]; earlier releases are
  summarised below from the git history rather than reconstructed in detail.
- **[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)** — added a licence-compatibility
  section confirming every bundled dependency is permissive (BSD-3-Clause, BSL-1.0,
  Apache-2.0, MIT, Unlicense) and therefore compatible with relicensing Goel° itself and
  with distributing it under a commercial licence. No bundled component carries a copyleft
  or field-of-use restriction.
- **[RELEASE.md](RELEASE.md)** — a tick-box manual release checklist covering one-time
  Apple/Sparkle setup, version bump, build and tests, tag-before-package, signing and
  notarisation, Gatekeeper verification, DMG, Sparkle appcast signing, and a rollback
  procedure whose first action is pulling the appcast item. This project has no CI; the
  checklist is what stands in for it.
- **Commercial licensing page** (`website/commercial.html`) — eligibility split, indicative
  pricing, an entitlement matrix, a stated response commitment, and an enquiry form backed
  by a small Cloudflare Worker (`website/_worker/enquiry.js`). The form posts to the site's
  own origin; no third-party form service and no tracking script is involved.
- **[docs/](docs/)** — getting started, FAQ, troubleshooting, and a reference for the
  remote-control JSON API.
- **[docs/compliance/](docs/compliance/)** — SBOM, a pre-answered security questionnaire and
  a support SLA, for buyers whose procurement asks for them before a purchase order.
- **Local diagnostics** (`GoelCore/Diagnostics`) — a privacy-preserving logging facade and an
  in-memory support report. The logger's message parameter is a `StaticString` and every
  runtime value must be passed as a field that declares its privacy class, so a URL, path or
  token *cannot* be interpolated into a log line — the compiler rejects it. The support
  report redacts through an explicit allow-list, and a test compares that list against the
  real settings keys so a new unclassified field fails the suite. Nothing here writes a file
  or opens a connection; there is still no user-facing export surface.

### Fixed

- **SFTP** — plain-language error messages in place of raw libssh2 codes, SSH key
  authentication, and correct handling of a Keychain access refusal instead of failing
  opaquely.
- **Builds** — local development builds are signed with a stable identity, so macOS keeps
  previously granted permissions across rebuilds rather than re-prompting every time.

> **Not yet done, and deliberately listed rather than quietly omitted.** The commercial
> licence still has owner placeholders to fill (contact addresses, pricing, trademark
> registration status) and has not been reviewed by a lawyer; the enquiry form needs its
> delivery destination configured before it goes anywhere; no Apple Developer certificate,
> notarisation profile or Sparkle signing key exists yet, so nothing in `RELEASE.md` has
> been executed end to end; and the diagnostics report has no user-facing export surface.

---

## [1.0.1] — 2026-07-18

Released under the **MIT License**. That grant is irrevocable and still applies to this tag.

### Added

- SFTP browser improvements: breadcrumb navigation, column sorting, multi-select,
  rename and move, and Quick Look preview.
- Live SFTP server status in the sidebar.
- Network aggregation — multi-path HTTP downloads across several interfaces, with a
  dedicated Aggregation settings tab and live adapter detection.
- Marketing website for `goel.vinitk.dev`, deployed via Cloudflare Workers.
- Cancel confirmation, calmer speed labels, and automatic retry.
- Persisted speed charts, and pruning of deleted downloads from the list.

### Fixed

- Menu-bar rows disappearing, and a single-stream connection stuck reporting 0%.
- Six computed mobile-layout overflows on the website.
- The clipboard banner no longer offers to download ordinary web pages.
- Queued rows now appear in the menu-bar popover.
- Steady speed readouts across the app via a shared `SpeedMeter`.
- Sidebar deduplicates host and IP, and gives the OS chip its own line.
- Upload-speed reporting during SFTP transfers.

---

## [1.0.0] — 2026-07-02

Released under the **MIT License**. That grant is irrevocable and still applies to this tag.

First public release: a native macOS download manager with one unified queue over
HTTP/HTTPS, FTP/FTPS, SFTP, BitTorrent and HLS; segmented multi-connection HTTP with
resume and mirror failover; full BitTorrent via libtorrent; an SFTP browser with host-key
pinning; browser-extension capture; menu-bar extra, Dock progress and AppleScript support;
watch folders and scheduling; an optional token-authenticated remote-control server; and a
headless `GoelDaemon` for Linux driven from a built-in web portal. Self-contained — every
native library bundled, no Homebrew required for end users.

---

[Unreleased]: https://github.com/vinitkumargoel/goel/compare/v1.0.4...HEAD
[1.0.4]: https://github.com/vinitkumargoel/goel/compare/v1.0.1...v1.0.4
[1.0.3]: https://github.com/vinitkumargoel/goel/compare/v1.0.1...v1.0.4
[1.0.2]: https://github.com/vinitkumargoel/goel/compare/v1.0.1...v1.0.4
[1.0.1]: https://github.com/vinitkumargoel/goel/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vinitkumargoel/goel/releases/tag/v1.0.0
