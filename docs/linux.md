# Goel° on Linux

Goel° on Linux is a **headless daemon plus a web portal**. There is no desktop app — the macOS
one is a separate build — so everything happens through the browser at `http://127.0.0.1:8080/`
and through the `goel` command.

```sh
curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh
```

That installs the service, generates a portal password, prints it once, and starts it. If you
would rather read the script first, that is the right instinct:

```sh
curl -fsSL https://goel.vinitk.dev/install.sh -o install.sh
less install.sh
sudo sh install.sh
```

---

## Requirements

| | |
|---|---|
| **OS** | Any Linux with **systemd** and **glibc** — Ubuntu 22.04+, Debian 12+, and their derivatives are what the installer is tested on |
| **Architecture** | `x86_64` or `aarch64` |
| **Root** | Yes, for the install; the daemon itself runs as an unprivileged `goel` user |
| **Disk** | ~250 MB for the release, plus whatever you download |

The dependency step uses `apt`. On Fedora, Arch, Alpine or anything else the installer says so
and continues — see [Other distributions](#other-distributions).

**Not systemd?** See [Without systemd](#without-systemd).

### What gets installed

| Path | What |
|---|---|
| `/opt/goel` | The release: `bin/GoelDaemon`, `bin/goel`, the bundled Swift runtime in `lib/`, `run.sh` |
| `/usr/local/bin/goel` | Symlink to the CLI |
| `/etc/goel/config` | Configuration, mode `0600`, root-only — it holds the portal password |
| `/var/lib/goel` | Queue database, generated API token, and downloads by default |
| `/etc/systemd/system/goel.service` | The unit |
| `/etc/systemd/system/goel.service.d/10-paths.conf` | Writable paths, maintained by `goel config sync` |
| a `goel` system user | No login shell, no home directory of its own |

`sudo goel uninstall` reverses all of it.

### Installer options

Every one of these is optional, and they go **before** `sh` so that `sudo` passes them through:

```sh
curl -fsSL https://goel.vinitk.dev/install.sh | sudo GOEL_PORT=9090 GOEL_LAN=true sh
```

| Variable | Default | Effect |
|---|---|---|
| `GOEL_VERSION` | latest release | Install a specific version |
| `GOEL_TARBALL` | — | Install from a local tarball instead of downloading |
| `GOEL_PORT` | `8080` | Portal port |
| `GOEL_LAN` | `false` | Serve to the network rather than loopback only |
| `GOEL_SAVE_DIR` | `/var/lib/goel/downloads` | Download folder |
| `GOEL_NO_START` | — | Install without enabling or starting the service |
| `GOEL_SKIP_DEPS` | — | Don't touch `apt`; you are supplying the libraries |
| `GOEL_INSECURE` | — | Install even if the release publishes no checksum |

Re-running the installer **upgrades in place**: it keeps `/etc/goel/config`, your queue and your
downloads, and only replaces `/opt/goel`. Your password is not regenerated and not reprinted.

---

## First five minutes

```sh
sudo goel status          # is it running, and where
sudo goel add <url>       # queue something
sudo goel list            # watch it
sudo goel doctor          # check the whole install
```

Most commands need `sudo`, because the config file and the API token are root-readable only.
Running one without it says so rather than pretending Goel° isn't installed.

Open `http://127.0.0.1:8080/` and sign in as `admin` with the password the installer printed. If
you missed it:

```sh
sudo goel config set password 'a new one'
```

### Reaching the portal from another machine

The daemon binds loopback only by default. To serve the LAN:

```sh
sudo goel config set lan true
sudo goel url                     # prints a URL including the API token
```

**This is plain HTTP.** The password and the API token cross the network unencrypted, so put
nginx or Caddy in front of it with TLS before using it anywhere you don't control. `goel doctor`
warns when the portal is exposed without one.

---

## The `goel` command

```
Service        status · start · stop · restart · enable · disable · logs [-f]
Configuration  config · config get/set/unset/sync · url · token [show|rotate]
Queue          add · list · pause · resume · retry · rm · adapters
Maintenance    doctor · uninstall [--purge] · version · help
```

`goel help` is the authoritative list. A few worth knowing about:

**`goel doctor`** is the first thing to run when something is wrong. It checks the binaries and
their shared libraries, the config file's permissions, the service state and whether it is
enabled at boot, whether the daemon can actually *write* to its download folder (as the `goel`
user, not as root — a very different question), whether the port is held by something else, and
whether the portal answers.

**`goel config`** edits `/etc/goel/config` and restarts the service so the change takes effect,
telling you if the restart failed. Settings are the friendly names `port`, `lan`, `auth`, `user`,
`password`, `token`, `save-dir`, `db`, `watch-dir`, `watch-autostart`, `aggregation`,
`aggregation-adapters`, `aggregation-streams`. Secrets are accepted but never printed back.

**`goel config sync`** rewrites the writable-paths drop-in from the config file. `set` and
`unset` do this for you; you need it by hand only if you edited `/etc/goel/config` directly.

**`goel token rotate`** invalidates every existing API client, which is the point.

---

## Configuration

`/etc/goel/config` is a systemd `EnvironmentFile`: plain `KEY=value` lines, `#` comments, no
shell expansion. The daemon reads these as its environment, so editing the file by hand is
entirely legitimate — just run `sudo systemctl restart goel` afterwards, and `sudo goel config
sync` if you changed a path.

| Key | Default | |
|---|---|---|
| `GOEL_PORT` | `8080` | Ports below 1024 are refused: the unit grants no `CAP_NET_BIND_SERVICE` |
| `GOEL_ALLOW_LAN` | `false` | `true` also needs a password, or the daemon stays on loopback |
| `GOEL_REQUIRE_AUTH` | `true` | |
| `GOEL_USERNAME` | `admin` | |
| `GOEL_PASSWORD` | generated | Plaintext, which is why the file is `0600` |
| `GOEL_TOKEN` | generated | Bearer token for the JSON API |
| `GOEL_SAVE_DIR` | `/var/lib/goel/downloads` | |
| `GOEL_DB` | `/var/lib/goel/queue.sqlite` | The API token is written next to it |
| `GOEL_WATCH_DIR` | unset | Folder watched for `.torrent` files |
| `GOEL_WATCH_AUTOSTART` | `false` | Start watched torrents without confirming |
| `GOEL_AGGREGATION` | unset | Split downloads across interfaces. Unset = whatever the portal last saved |
| `GOEL_AGGREGATION_ADAPTERS` | unset | Interfaces to split across, comma-separated. Empty = every eligible one |
| `GOEL_AGGREGATION_STREAMS` | `2` | Connections opened per interface, 1–8 |

### Using more than one network interface

Machines with two uplinks can spread a download across both, or send a particular download out
of a particular one. `goel adapters` shows what is available:

```
INTERFACE   NAME              TYPE   ADDRESS        USABLE  IN SPLIT
wlp13s0     Wi-Fi (wlp13s0)   wifi   192.168.0.218  yes     yes
wlx782051…  Wi-Fi (wlx78…)    wifi   192.168.0.219  yes     yes

  aggregation             off
  streams per interface   2
```

Turn splitting on for everything with `sudo goel config set aggregation on`, or choose per
download with `goel add <url> --net single:wlp13s0` (also `--net aggregate`, or
`--net aggregate:wlp13s0,eth0`). The web portal offers the same choice in its Add dialog and a
Settings section, so a headless box needs no shell for this.

> **Measure before you trust it.** Splitting helps only when each interface has its own upstream
> link. Two adapters behind the same router share one pipe: on the machine this feature was
> developed against, 17.7 MB/s and 12.9 MB/s individually became 7.8 + 7.9 MB/s together —
> slower than either one alone. A second ISP, or a cellular modem alongside a wired link, is the
> case where this pays.

#### If a pinned download times out with an interface that looks fine

`goel adapters` reports what the kernel says: a name, an address, a route. None of that proves
packets sent *out of that specific interface* come back, and two of the ways it can fail are
common enough to check first. Both were hit on the development machine.

**Two interfaces on the same subnet.** Linux answers ARP for any of its addresses on any
interface by default, so the router can learn interface A's address at interface B's MAC. Replies
then arrive on the wrong interface, and a socket bound to the right one never sees them —
every download through it times out while ordinary, unbound traffic is perfectly healthy. The
fix is per-interface ARP discipline:

```sh
sudo sysctl -w net.ipv4.conf.all.arp_ignore=1 net.ipv4.conf.all.arp_announce=2
# make it persist
printf 'net.ipv4.conf.all.arp_ignore=1\nnet.ipv4.conf.all.arp_announce=2\n' \
  | sudo tee /etc/sysctl.d/60-goel-multihoming.conf
```

**An address without a route.** `ip route show` must contain a route whose device is that
interface. NetworkManager gives a second adapter an address but usually leaves the default route
on the first, so the second has no way out and binding to it fails with "no route to host". Two
uplinks need one routing table each plus a rule selecting them by source address (`ip rule add
from <addr> table <n>`) — a standard policy-routing setup, and the same thing that makes
splitting actually use both links rather than sending everything down one.

A transport failure names the interface it was bound to, so the queue tells you which one is at
fault rather than reporting a bare "could not connect".

Leaving `GOEL_AGGREGATION` unset — the default — means the portal's toggle is the authority and
survives restarts. Setting it in `/etc/goel/config` makes the file authoritative: the portal can
still change it, but the next restart puts it back, and the portal says so rather than implying
the change stuck.

Two things remove the choice entirely, because binding a socket to an interface would bypass
them: a configured proxy (`system` or `manual`), and a VPN holding the default route. In both
cases `goel adapters` reports every interface as not usable, which is the honest answer.

Aggregation applies to HTTP(S) downloads. Torrents manage their own connections, and FTP/SFTP
are single-stream by nature.

### Writable paths, and why a download can fail on write

The unit runs with `ProtectSystem=strict`, so **the whole filesystem is read-only to the daemon
except the paths named in the drop-in**. That set depends on your configuration, which is why it
lives in `10-paths.conf` rather than in the unit, and why `goel config` maintains it.

The failure mode when it is wrong is nasty: the service starts perfectly and every single
download fails the moment it tries to write. `goel doctor` tests this directly by writing a probe
file as the `goel` user.

If you point `save-dir` somewhere new, use `goel config set` rather than editing the file — it
creates the directory, gives the `goel` user ownership, updates the drop-in and reloads systemd
in one step. It also **refuses a path that is a symbolic link**, because a recursive `chown`
through a link someone else planted is a way to hand your service account ownership of `/etc`.

### Downloads under `/home`

This works and is expected — `ProtectHome` is deliberately not set. Two things to know:

- `goel config set save-dir /home/you/Downloads` adds it to the drop-in for you.
- The files end up owned by `goel`, mode `0750` (`UMask=0027`), so *you* may need to be in the
  `goel` group to read them: `sudo usermod -aG goel $USER`, then log out and back in.

---

## Upgrading

```sh
curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh
```

`/opt/goel` is replaced by an atomic swap, so a failed upgrade never leaves the machine without a
working copy. Configuration, the queue database and downloads are untouched. Check `goel version`
and `goel doctor` afterwards.

To pin a version, or to go back:

```sh
curl -fsSL https://goel.vinitk.dev/install.sh | sudo GOEL_VERSION=1.0.3 sh
```

---

## Uninstalling

```sh
sudo goel uninstall            # removes the service and /opt/goel; keeps config, queue, downloads
sudo goel uninstall --purge    # also deletes /etc/goel, /var/lib/goel and the goel user
```

`--purge` deletes your downloads. Both ask you to type a word to confirm; `--yes` skips that for
automation. If a step doesn't complete, the command names which one rather than reporting success.

---

## Troubleshooting

Always start here:

```sh
sudo goel doctor
sudo goel logs -n 100
```

**The service won't start.** `goel logs` has the daemon's own reason. The usual causes are a port
already in use (`goel doctor` names the process holding it) and a save folder outside the
writable set (`sudo goel config sync`).

**Every download fails instantly.** Almost always writable paths — see above. `goel doctor`'s
"can write to the download folder" check is the definitive test.

**`missing shared libraries`.** The tarball bundles the Swift runtime, libtorrent and Boost, but
leaves OpenSSL, libcurl and libssh2 to your distribution so they keep getting security updates.
Find the package providing what's missing:

```sh
sudo apt install apt-file && apt-file update
apt-file search libssh2.so.1
```

then install it and re-run the installer. Package names for these moved in Debian's 64-bit
`time_t` transition — `libssh2-1` on 24.04 is `libssh2-1t64` on 26.04 — which is why the
installer resolves them rather than hardcoding them.

**`goel: this needs root`.** Add `sudo`. The config file and the API token are root-only by
design.

**`/etc/goel/config is missing`.** That one genuinely means not installed — an unreadable file
reports as needing root instead.

**The portal is unreachable but the service is active.** Check the port with `goel status`, and
remember that `lan=false` means loopback only: from another machine you'll need
`goel config set lan true` (and TLS in front).

For anything else, see [troubleshooting.md](troubleshooting.md).

---

## Without systemd

Containers, WSL without systemd, and minimal images are all reasonable places to want the daemon.
The installer refuses because it has no service to install into, so run the daemon directly.
Download the tarball from [Releases](https://github.com/vinitkumargoel/goel/releases), unpack it,
and use `run.sh` — it sets `LD_LIBRARY_PATH` for the bundled `lib/` and then execs the daemon:

```sh
tar xzf goel-daemon-*-linux-x86_64.tar.gz
cd goel-daemon-*-linux-x86_64
GOEL_PORT=8080 GOEL_USERNAME=admin GOEL_PASSWORD='a real password' ./run.sh
```

Every `GOEL_*` variable in the table above works as an environment variable — that is exactly
what the config file is. The `goel` CLI manages a *systemd service*, so it is not much use here;
use the portal and the [JSON API](remote-api.md) instead.

In Docker, mount a volume for `GOEL_DB` and `GOEL_SAVE_DIR` so the queue survives the container,
and remember that a daemon on loopback inside a container is not reachable from outside it —
either publish the port and set `GOEL_ALLOW_LAN=true`, or use host networking.

---

## Other distributions

The prebuilt tarball works on any glibc distribution of the right architecture; only the
dependency *installation* is Debian-specific. Install the equivalents of these yourself, then run
the installer with `GOEL_SKIP_DEPS=1`:

| Need | Fedora / RHEL | Arch | Alpine |
|---|---|---|---|
| libssh2 | `libssh2` | `libssh2` | not glibc — build from source |
| libcurl | `libcurl` | `curl` | |
| OpenSSL 3 | `openssl-libs` | `openssl` | |
| ffmpeg | `ffmpeg` | `ffmpeg` | |

Alpine uses musl rather than glibc, so the prebuilt tarball will not run there at all — build
from source.

---

## Build from source

Needed for architectures with no prebuilt release, and for musl distributions.

```sh
# Swift 6.1+ — see https://www.swift.org/install/linux/
# gcc, NOT clang: the Swift toolchain ships its own clang, and apt's replaces
# /usr/bin/clang with one that rejects -index-store-path — every C target then
# fails to compile. build-sqlite.sh uses `cc`, which gcc provides.
sudo apt install libtorrent-rasterbar-dev libssh2-1-dev libcurl4-openssl-dev \
                 libssl-dev libboost-dev libboost-system-dev libsqlite3-dev \
                 gcc pkg-config

git clone https://github.com/vinitkumargoel/goel.git && cd goel

# GRDB needs a snapshot-enabled SQLite; the stock one declares sqlite3_snapshot_*
# without defining it.
Scripts/linux/build-sqlite.sh
export GOEL_SQLITE_DIR="$PWD/Vendor/linux/sqlite"

GOEL_VERSION=dev Scripts/linux/package_daemon.sh
```

That produces `dist/goel-daemon-dev-linux-<arch>.tar.gz` and its `.sha256`, which you can install
with the normal script:

```sh
sudo GOEL_TARBALL="$PWD/dist/goel-daemon-dev-linux-$(uname -m).tar.gz" sh website/install.sh
```

`swift build -c release` alone builds the binaries but not the runtime closure, the licences or
the unit file, so use the packaging script for anything you intend to install.

---

## See also

- [getting-started.md](getting-started.md) — the concepts, shared with macOS
- [remote-api.md](remote-api.md) — the JSON API the CLI itself uses
- [troubleshooting.md](troubleshooting.md) — symptoms across all platforms
- [faq.md](faq.md) — including what exposing the portal actually means
