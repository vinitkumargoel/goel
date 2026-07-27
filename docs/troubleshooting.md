# Troubleshooting

If nothing here fixes it, open an issue at
[github.com/vinitkumargoel/goel/issues](https://github.com/vinitkumargoel/goel/issues)
with what you did, what you expected and what happened. Business and Enterprise licensees
have a support channel with a response SLA — see [support-sla.md](compliance/support-sla.md).

---

## Installing and launching

### macOS refuses to open the app

Right-click `Goel°.app` → **Open** → confirm. That is Gatekeeper's standard first-run
prompt for an app downloaded outside the App Store; you only see it once.

### The app opens and immediately quits

Almost always a mismatched native library. Two different causes:

**A downloaded `1.0.0` or `1.0.1` release, on a Mac older than macOS 26.** Those two
archives were built before the deployment-target gate existed, and the OpenSSL and
libtorrent dylibs vendored into them declare a minimum of macOS 26.0 (libssh2 declares
15.0) while the app itself advertises 14.0. dyld refuses an over-targeted library before
the app's own code runs, so there is no error dialog to read — it just quits. Confirm it
on a copy you hold:

```bash
Scripts/check_min_os.sh "/Applications/Goel°.app"
```

There is no workaround short of a newer release or a build of your own; the gate now runs
in both `Scripts/build_app.sh` and `Scripts/make_dmg.sh`, so no later archive can carry
the mismatch.

**A build made from source.** Rebuild with `swift build -c release` and check that
libtorrent-rasterbar, libssh2 and OpenSSL 3 are installed under the Homebrew prefix the
build used. Set `GOEL_BREW_PREFIX` if yours is not `/opt/homebrew`. If `check_min_os.sh`
reports over-targeted dylibs, your Homebrew bottles were poured for a newer macOS than the
app targets — rebuild them with `MACOSX_DEPLOYMENT_TARGET=14.0`, or build on macOS 14.

### macOS asks for permissions again after every rebuild

Local builds are signed with a stable identity precisely so macOS keeps its grants
between builds. If you are re-signing manually with an ad-hoc identity, the system sees
each build as a different app and re-asks. Use the project's build script.

---

## Downloads

### A download fails immediately

Check the task's error text — it is written in plain language rather than a library error
code. Common causes:

| Symptom | Likely cause |
|---|---|
| "No such file or directory" on SFTP | The remote path is wrong, or relative when it should be absolute |
| Authentication failed | Wrong credentials, or a key the server does not accept |
| Connection refused | Wrong port, or the service is not running |
| Certificate error on FTPS/HTTPS | Self-signed or expired certificate on the server |

### Nothing downloads and speed stays at 0

- **Torrents:** you may have no reachable peers. Check the **Trackers** tab for tracker
  errors, and confirm DHT is enabled if you are using a magnet with no working tracker.
- **HTTP:** the server may be refusing multi-connection requests. Reduce the connection
  count for that task.
- All protocols: check that a global or per-task speed limit is not set to something
  tiny, and that the scheduler is not currently in a throttled window.

### A magnet link sits at "Requesting metadata"

The magnet has no reachable peers yet. Metadata comes from peers, not from the magnet
itself, so this can take a while on a poorly-seeded torrent — or forever, if nobody is
seeding it. Confirm DHT is on and the trackers in the magnet are responding.

### A resumed download restarts from zero

The server did not honour the range request. Some servers, and most CDNs serving dynamic
URLs, do not support resume. There is nothing the client can do about that.

### Downloaded files are missing

Check the task's **Save path** in the detail pane — it may have gone to a per-task folder
rather than your default. It will not have gone somewhere you did not name: if the request
came through the web portal and asked for a folder outside the configured downloads root,
`POST /api/add` refuses the whole request with `403` and adds nothing, rather than quietly
saving elsewhere.

### A torrent shows 100% but keeps running

That is **seeding**, not a stuck download. It uploads to other peers until your seeding
rules stop it. Stop it manually, or set a **share-ratio** limit — per task from the
download's **Seed Until Ratio** menu, or for every torrent from the traffic profile's
seed-ratio figure in **Settings → Traffic Limits**. (There is no seeding-*time* limit;
ratio is the only automatic stop.) A per-task ratio of `0` means "seed indefinitely" and
overrides the profile.

### An `.m3u8` stream is refused instead of downloading

HLS downloads deliberately fail loudly rather than produce a file that looks fine until you
play it. The error text names which case you hit:

| Refusal | Why |
|---|---|
| "This is a live HLS stream (no `#EXT-X-ENDLIST`)" | A live playlist has no end to download to. The file would stop at whatever had been published when the walk reached it, and report success. Only finished (VOD) streams can be downloaded. |
| "…delivers its audio as a separate track that this downloader can't mux in" | The variant's audio is a separate `#EXT-X-MEDIA` rendition and the variant declares no audio codec of its own. Fetching the video alone would give you a silent file. |
| "…uses DRM (`KEYFORMAT=…`) encryption, which this downloader can't decrypt" | FairPlay, Widevine or any non-`identity` key format. Unencrypted and AES-128 streams work; nothing else does, and the licence endpoint is never contacted. |
| "The assembled HLS file is empty" | Segments arrived but the remux produced no playable output. The segment cache is kept so a retry does not re-download. |

There is no override for any of these — an option to save the file anyway would just be the
truncated or silent file with an extra click in front of it.

---

## The browser extension

Full install instructions and a per-browser capability matrix are in
[browser-extension.md](browser-extension.md); this covers what goes wrong.

### "Download with Goel°" appears to do nothing

Hover the extension's toolbar button — it reports the outcome of the last hand-off on its
badge and tooltip. A red `!` and *"can't reach the app"* means the native-messaging helper is
missing or points at an old app location. Fix it in two steps:

1. Goel° ▸ Settings ▸ Browser Integration ▸ **Install Helper**.
2. **Fully quit and reopen the browser** — host manifests are read at startup.

The helper only configures browsers whose support directory already exists, so if it reports
*"No supported browsers found"*, launch the browser once and click it again. Moving or
reinstalling `Goel°.app` also invalidates it, because the wrapper script embeds the app's
path — re-run **Install Helper** after either.

### The extension says the app refused the link

Captures are restricted to `http:`, `https:` and `magnet:`, and the target may not be a
loopback or link-local address. That is deliberate: without it, a web page could use the
extension to make Goel° fetch a service on your machine that was never exposed to the
browser. Such a URL can still be added by hand in the Add sheet, where you are the one
choosing it.

### Capture mode is ON but downloads still go to the browser

In **Safari this never works** — Safari has no `downloads` API, so only the right-click menu
is available there (the toolbar button says so when clicked). Elsewhere, only `http(s)`
downloads *started after* you enabled it are captured; one already in flight is left alone.

### A download behind a login comes back as a login page

- An amber `!` after the send means the cookies were dropped. In **Safari that is by design**:
  its sandbox's only route to the app is a URL, which LaunchServices logs, and a session
  cookie must not be written anywhere that gets logged. Use Chrome or Firefox.
- Otherwise the optional cookie permission is probably not granted for that site. Use
  right-click → **Download with Goel° (stay signed in)** and accept the prompt.
- If Goel° stayed closed for more than an hour after the capture, the cookie was dropped from
  the spool on purpose and the URL queued without it. Retry with the app open.

### The extension disappeared after restarting Firefox

Expected — Firefox discards temporary add-ons on quit, and no signed `.xpi` is published.
Reload it from `about:debugging#/runtime/this-firefox`, or use a Chromium-family browser,
where it persists.

### Goel° Capture is not in Safari's extension list

The app must be in `/Applications`, and Safari must have been quit and reopened since it was
installed — Safari does not scan other locations for app extensions. A self-built (ad-hoc
signed) copy additionally needs Safari ▸ Develop ▸ **Allow Unsigned Extensions**, which
resets every time Safari restarts.

---

## SFTP and SSH

### SSH key authentication is refused

- The key must be one libssh2 supports. RSA, ECDSA and Ed25519 are the usual working set;
  very old or exotic formats are not.
- If the key has a passphrase, Goel° needs it, and it is stored in the Keychain.
- Check permissions on the key file. `ssh` and libssh2 both refuse world-readable keys.

### macOS keeps asking to unlock the Keychain

Choose **Always Allow** on the prompt. If you previously chose **Deny**, the app is being
refused access permanently; open **Keychain Access**, find the Goel° item, and reset its
access control. A refusal is reported as a plain "the Keychain refused access" message
rather than being silently swallowed.

---

## Linux (the daemon and the `goel` command)

**`sudo goel doctor` first.** It checks the shared-library closure, the config file's permissions,
the service state and its boot enablement, whether the daemon can write to its download folder
*as the `goel` user*, whether the port is free, and whether the portal answers — which is most of
this section, run for you. Then `sudo goel logs -n 100`.

### Every download fails the instant it starts

Writable paths. The unit runs with `ProtectSystem=strict`, so the whole filesystem is read-only to
the daemon except the paths in `/etc/systemd/system/goel.service.d/10-paths.conf`. If that file is
missing or stale, the service still starts perfectly and every write is denied:

```sh
sudo goel config sync      # rewrite it from /etc/goel/config
```

`goel doctor` reports both a missing drop-in and one that no longer covers your configured paths.
Always change a path with `sudo goel config set save-dir …` rather than by editing the config file
— it creates the directory, gives the `goel` user ownership and updates the drop-in in one step.

### `goel: this needs root`

Add `sudo`. `/etc/goel/config` and the API token are root-only, deliberately, so even read-only
commands like `goel status` need it.

### `/etc/goel/config is missing — Goel° does not look installed`

That one means what it says. An *unreadable* config file reports as needing root instead, so this
is not a disguised permissions problem.

### `error while loading shared libraries` / `goel doctor` says libraries are unresolved

The tarball bundles the Swift runtime, libtorrent and Boost, but leaves OpenSSL, libcurl and
libssh2 to your distribution so they keep receiving security updates. Find the package:

```sh
sudo apt install apt-file && sudo apt-file update
apt-file search libssh2.so.1
```

then install it and re-run the installer. If one of the *bundled* libraries is the missing one, the
release is incomplete — reinstall rather than hunt for a package.

### The service won't start

`sudo goel logs` has the daemon's own reason. Usually either the port is taken (`goel doctor` names
the process holding it) or the database path is wrong — note that `db` is a *file*, and a directory
sitting where the file should be leaves SQLite unable to open it.

### It runs now but is gone after a reboot

It was started but not enabled: `sudo goel enable`. `goel doctor` checks this separately from
whether it is currently active.

### The portal is unreachable but the service is active

`lan` defaults to `false`, which means loopback only. From another machine you need
`sudo goel config set lan true` — and TLS in front of it, because the portal speaks plain HTTP and
the password and token cross the network unencrypted.

### `goel uninstall` said "Mostly removed"

It names which steps did not complete. The usual one is the `goel` user still being in use: check
`pgrep -u goel`, then re-run the uninstall.

Everything else Linux-specific is in [linux.md](linux.md).

---

## The web portal

### "Not signed in" when calling the API

The request carried no valid credential. Send `Authorization: Bearer <token>` or append
`?token=<token>`. Browsers use the session cookie from `POST /login` instead. Note the
token is compared in constant time, so a wrong token takes the same time as a right one —
that is not the API being slow.

### Every POST returns 403

Read-only mode is on. Turn it off in **Settings → Web Access** if you want the portal to
be able to change the queue.

### 429 "Too many attempts"

Login lockout: five failed attempts triggers a 30-second cool-off. Wait it out. A separate
429 ("Server busy") appears if too many password verifications are in flight at once —
password hashing is deliberately expensive, and that cap is what stops it being used as a
CPU-exhaustion vector.

### The live view stops updating

The SSE stream (`GET /api/events`) ends when the server restarts, when credentials are
rotated, or when the connection drops. It is capped at 4 concurrent streams; a fifth gets
`503 Too many live streams`. Reload the page.

### Streaming a video returns 409

`409 Conflict — Not streamable yet` means the bytes needed are not on disk in order.
Enable **sequential mode** on that task, or wait for it to finish.

### The portal is unreachable from another device

- Confirm it is not bound to loopback only.
- Check the macOS firewall.
- Total connections are capped at 32; a busy portal can refuse a new one.
- There is no TLS in the portal itself. If you need it over a hostile network, use a
  reverse proxy or a VPN.

---

## Performance

### High CPU while torrenting

Piece verification is CPU-heavy, particularly right after a **force recheck** on a large
torrent. It settles once verification completes.

### The queue feels sluggish with very many tasks

The task list is indexed for lookup, so size alone should not hurt. If it does, capture
what you were doing and file an issue — that is a bug, not expected behaviour.

---

## Getting useful information into a bug report

Include:

- Goel° version, macOS (or distro) version, and whether the build came from Releases or
  from source.
- The protocol involved and, if you can share it, the kind of source (an ordinary HTTPS
  URL, a magnet, an SFTP path — the URL itself is rarely needed).
- The exact error text from the task detail pane.
- For portal problems: the HTTP status code and whether you were using a token or a
  session cookie.

Please do not paste credentials, tokens or full private URLs into a public issue.
