# The `goel` command

`goel` is the terminal client for the Goel° download engine. It talks to a running
daemon (`GoelDaemon` on Linux or macOS) over the same token-authenticated local HTTP API
the web portal uses — one queue, three faces: CLI, web portal, native app.

The short version, and the reason this page exists:

```bash
goel https://example.com/ubuntu.iso
```

downloads the file — segmented, resumable, rate-limited, recorded in history, visible in
the web portal while it runs — and **blocks until it is on disk**, then prints the saved
path. It is `curl -LO` with a download manager behind it.

This page is the complete reference: every command, every flag, the exit-code contract,
the JSON output shapes, and the environment variables — written so both people and
automation agents can drive `goel` without reading the source.

---

## Agent quick reference

```bash
goel <url>                      # download, wait, exit 0 when saved (curl parity)
goel <url> --json               # same, then print the final task detail as JSON
goel <url> --timeout 300        # stop waiting after 5 min (download continues) → exit 4
goel add <url> …                # queue and return immediately (async)
goel add <url> --wait           # queue and block (same as the shorthand)
goel list --json                # active downloads as JSON
goel list --all --json          # everything, verbatim portal reply
goel status --json              # daemon/portal/queue state as JSON
goel url                        # web-portal link (carries the API token)
goel doctor                     # self-check with fix-it advice, exit 1 if broken
```

**Exit codes — a stable contract, never renumbered:**

| Code | Meaning |
|---|---|
| `0` | Success. In wait mode: every download completed. |
| `1` | Runtime error — portal unreachable, HTTP error, malformed reply. |
| `2` | Usage error — the command line itself was wrong. |
| `3` | The download did not happen: every source refused, or a waited download failed. |
| `4` | `--timeout` expired while still downloading — the download continues server-side. |
| `130` | Ctrl-C during a wait — the download itself keeps going (`goel list` to watch). |

**Environment variables** (each overrides the config file):

| Variable | Effect |
|---|---|
| `GOEL_CONFIG` | Path to the config file to use, instead of the resolution order below. |
| `GOEL_PORT` | Portal port to talk to (default 8080). |
| `GOEL_TOKEN` | API bearer token. With this set, no config file is needed at all. |

A stateless agent can therefore drive any local daemon with:

```bash
GOEL_PORT=8899 GOEL_TOKEN=$TOKEN goel https://example.com/data.bin --json
```

**JSON rules:** `--json` output goes to stdout, one JSON document per run; diagnostics go
to stderr. Wait mode always emits an **array** of task-detail objects (one per URL, in
request order), whatever the count — callers never branch on shape. Exit 3 always
carries a JSON document (the add reply, the detail array, or `{"error": "…"}`); on exit
1 or 2 stdout may be empty and the reason is on stderr.

---

## How `goel` finds the daemon

The CLI needs two facts: the portal **port** and the API **token**. It reads them from,
in order:

1. **`$GOEL_CONFIG`** — explicit config-file path, wins outright.
2. **`/etc/goel/config`** — the Linux system install (created by `install.sh`; root-only,
   hence `sudo` on those machines).
3. **`~/.config/goel/config`** — the portable install; created by `goel config set …`
   without root. (`$XDG_CONFIG_HOME` is honoured.)

`GOEL_PORT` / `GOEL_TOKEN` in the environment override whichever file was found — and if
`GOEL_TOKEN` is set, the CLI works with **no config file at all**.

If the config names no token, the CLI falls back to the token file the daemon writes on
first start (`portal-token`, next to the queue database).

The daemon resolves its configuration the same way (file read at start, environment
wins), so one file drives both sides. The API itself is loopback-only from the CLI —
`goel` never sends the token across a network.

## The two install shapes

**System install (Linux + systemd).** `curl -fsSL https://goel.vinitk.dev/install.sh |
sudo sh` — daemon as a systemd unit under the unprivileged `goel` user, config in
`/etc/goel/config`, `goel start/stop/enable/logs` manage the unit. Full guide:
[linux.md](linux.md).

**Portable install (macOS, or Linux without root).** Get the two binaries — on macOS
that is from source today:

```bash
brew install libtorrent-rasterbar openssl@3 libssh2 boost   # build-time only
swift build -c release --product goel
swift build -c release --product GoelDaemon                 # both land in .build/release
```

Then:

```bash
goel config set port 8899          # writes ~/.config/goel/config (0600, no root)
goel config set token $(openssl rand -hex 24)
goel config set save-dir ~/Downloads/goel
GoelDaemon &                       # reads the same config file
goel https://example.com/file.iso  # everything works: CLI, web portal, JSON
```

The service commands (`start`, `stop`, `enable`, `logs`) are systemd-only and say so;
everything else — download, queue, config, doctor, web — is identical in both shapes.

---

## Commands

### `goel <url> [<url>…] [flags]` — download and wait

Any argument that looks like a download source makes the whole invocation a download:
schemes `http://`, `https://`, `ftp://`, `ftps://`, `sftp://`, and `magnet:` links —
including `.torrent` and `.m3u8` URLs, which route to the BitTorrent and HLS engines.

The sources are queued on the daemon, then followed until every one reaches a terminal
state. On a terminal you get a live progress line (name, percent, speed, ETA); piped or
in a script, progress is silent and only results print.

| Flag | Meaning |
|---|---|
| `--detach`, `-D` | Queue and return immediately — don't wait (same as `goel add`). |
| `--timeout N`, `-t N` | Stop waiting after N seconds → exit 4. The download continues. |
| `--folder DIR`, `-d` | Save into DIR instead of the daemon's default. Must be writable by the *daemon's* user, else the whole add is refused (403 → exit 3). |
| `--priority P`, `-p P` | `skip` \| `low` \| `normal` \| `high`. |
| `--paused` | Queue without starting. Implies not waiting. |
| `--net SPEC`, `-n` | `auto` \| `single:<iface>` \| `aggregate` \| `aggregate:<a>,<b>` — which interface(s) this download egresses (`goel adapters` lists them). |
| `--json` | Emit the final task-detail array on stdout. |

Behaviour worth knowing:

- **Ctrl-C detaches, it does not cancel.** The download lives on the daemon; the CLI is
  only watching. Exit 130, and `goel list` picks it back up. To actually cancel:
  `goel rm <id>`.
- **A URL you already downloaded deduplicates**: if the task is complete and the file is
  still on disk, the command returns `Saved` immediately with exit 0 — re-running the
  same `goel <url>` is idempotent and cheap. If the file has since been deleted, the
  daemon downloads it afresh; if the earlier attempt failed, adding the URL again
  retries it. In every case, exit 0 means the payload is on disk right now.
- **Mixed outcomes exit 3**: with several URLs, any refused source or failed download
  makes the exit non-zero, even if others saved. Read the per-URL lines (or the JSON
  array) for the breakdown.
- **Torrents count as done at completion** — when the payload is fully on disk — even
  though the daemon may continue seeding per its share-ratio settings.
- On success, each saved file prints as `Saved /absolute/path`. With `--json`, the
  detail objects carry `savePath`, `row.statusToken`, sizes, and (for torrents) files
  and trackers — the same shape as `GET /api/task` in [remote-api.md](remote-api.md).

### `goel add <url> [<url>…] [flags]` — queue asynchronously

Same flags as above, plus `--wait`/`-w` to opt back into blocking. Without `--wait` it
prints `Added N` and returns; with `--json` it prints the portal's reply verbatim:

```json
{ "added": 1, "refused": 0, "ids": ["6B0877A8-…"] }
```

`ids` are the queued task UUIDs (request order) — poll them, pause them, or pass one to
`goel rm`. Exit 0 only if something was added and nothing was refused; otherwise 3.

### `goel list [--all] [--json]` (alias `ls`) — the whole queue in one command

Without `--all`: everything not yet completed (queued, downloading, paused, seeding,
failed — failures print their reason under the table). With `--all`: finished downloads
too. `--json --all` is the portal's `/api/tasks` reply verbatim; `--json` without
`--all` is the same rows filtered to `statusToken != "completed"`.

IDs print truncated to 8 characters; every command that takes an ID accepts any
unambiguous prefix.

### `goel status [--json]`

Service state (systemd boxes), portal URL and bind mode, sign-in requirement, config /
database / downloads paths, and a live queue summary. In JSON, `portal.reachable` says
whether the queue numbers are real; when the portal is down, `portal.error` says why
**and the exit code is 1** — `goel status --json` is the liveness probe, safe to gate
scripts on. (Human-facing `goel status` stays informational and exits 0.)

### `goel pause <id|all>` · `goel resume <id|all>` · `goel retry <id>` · `goel rm <id> [--data]`

Queue surgery. `rm` keeps downloaded files unless `--data` is given. `retry` re-runs a
failed task.

### `goel url` · `goel web`

`url` prints the portal link **with the API token embedded** (treat it as a password —
the warning goes to stderr so the URL itself stays pipeable). `web` prints it and opens
the browser (`open` on macOS, `xdg-open` under a graphical Linux session). The browser
is handed a private redirect file (`~/.config/goel/open-portal.html`, mode 0600), not
the link itself, so the token never appears in another process's arguments where `ps`
or audit logs would capture it.

### `goel adapters`

The daemon's view of the network interfaces: which are eligible for multi-interface
aggregation, which are in the current split, and the per-download override syntax.

### `goel config` — settings

```
goel config                  # list every setting (secrets shown as set/unset)
goel config get <key>
goel config set <key> <val>  # creates the user config if none exists; restarts a running service
goel config unset <key>
goel config sync             # systemd only: refresh the unit's writable-paths drop-in
```

Keys: `port`, `lan`, `auth`, `user`, `password`, `token`, `save-dir`, `db`, `watch-dir`,
`watch-autostart`, `aggregation`, `aggregation-adapters`, `aggregation-streams` — the
same `GOEL_*` keys the daemon reads, documented per-key in [linux.md](linux.md). Values
set in your environment show as `(from $GOEL_…)` in the listing, because they outrank
the file — and `config get` answers with the same precedence, so it always reports the
value goel actually operates with. On a system install `set`/`unset` need `sudo`; on a
portable install they don't (and refuse to run under `sudo` if the target directory
belongs to a non-root user — root must not write into a location another account
controls).

### `goel token [show|rotate]`

Prints or regenerates the API bearer token. Rotation restarts a running service and
invalidates every stored portal link and paired client.

### `goel start` · `stop` · `restart` · `enable` · `disable` · `logs [-f] [-n N]`

systemd service management; on a machine without systemd they explain the portable
alternative instead. `logs` follows the journal.

### `goel doctor`

The whole install, checked, with a fix-it line for everything wrong: config presence and
permissions, service state, writable paths, port, ffmpeg (HLS), LAN-exposure sanity, and
a live portal probe. Exit 1 if any check fails — safe to use in provisioning scripts.
On a portable install the Linux-installer checks are skipped rather than failed.

### `goel uninstall [--purge] [--yes]` · `goel version` · `goel help`

`uninstall` removes the systemd service and install (with `--purge`, also config, queue
database and the `goel` user — it asks for a typed confirmation unless `--yes`).

---

## Recipes

**Download to a specific folder, fail loudly, capture the path:**

```bash
path=$(goel https://example.com/model.gguf -d /srv/models --json \
       | jq -r '.[0].savePath') || echo "download failed with $?"
```

**Queue a batch, watch it from the web:**

```bash
goel add https://a/1.iso https://b/2.iso https://c/3.iso
goel web
```

**Bounded wait in CI (10 minutes, then leave it running):**

```bash
goel https://example.com/dataset.tar --timeout 600
case $? in
  0) echo saved ;;
  4) echo "still downloading — check later with: goel list" ;;
  *) exit 1 ;;
esac
```

**A torrent, with files kept out of the default folder:**

```bash
goel "magnet:?xt=urn:btih:…" -d /srv/media/linux-isos
```

**Point one invocation at a different daemon:**

```bash
GOEL_PORT=9090 GOEL_TOKEN=$OTHER_TOKEN goel list --json
```

**Is anything failing right now? (agent health check):**

```bash
goel list --json | jq -e 'map(select(.statusToken=="failed")) | length == 0'
```

---

## Running without systemd

`GoelDaemon` is an ordinary foreground process — run it under launchd, tmux, Docker,
runit, or a shell `&`. It reads the same config file as the CLI (environment variables
win), creates its paths on start, writes `portal-token` next to the database if no token
is configured, and serves the web portal and API until SIGINT/SIGTERM.

The config file must be owned by the user the daemon runs as (or root) and must not be
world-writable; otherwise the daemon warns on stderr and runs on environment variables
and defaults only. This stops a `sudo -E`-preserved `$GOEL_CONFIG`/`$XDG_CONFIG_HOME`
from steering a privileged daemon to a file another user controls.

```bash
GoelDaemon                              # config from ~/.config/goel/config or /etc/goel/config
GOEL_CONFIG=/srv/goel/config GoelDaemon # explicit file
GOEL_PORT=8899 GOEL_TOKEN=… GoelDaemon  # pure environment, no file
```

The Linux specifics (systemd unit, `ProtectSystem=strict`, the `goel` service user) are
in [linux.md](linux.md) — none of them apply to a portable run.

## See also

- [remote-api.md](remote-api.md) — the JSON routes the CLI drives, if you want to skip
  the CLI and speak HTTP directly.
- [linux.md](linux.md) — the system install end to end.
- [getting-started.md](getting-started.md) — the desktop app.
- [troubleshooting.md](troubleshooting.md) — when something misbehaves.
