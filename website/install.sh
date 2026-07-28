#!/bin/sh
# Everything lives inside main(), called on the last line: a truncated `curl | sh` must do nothing.

set -eu

REPO="vinitkumargoel/goel"
INSTALL_ROOT="/opt/goel"
CONFIG_DIR="/etc/goel"
CONFIG_FILE="/etc/goel/config"
STATE_DIR="/var/lib/goel"
UNIT_FILE="/etc/systemd/system/goel.service"
DROPIN_DIR="/etc/systemd/system/goel.service.d"
SERVICE_USER="goel"
CLI_LINK="/usr/local/bin/goel"

DEPENDENCY_ALTERNATIVES="
libssh2-1t64|libssh2-1
libcurl4t64|libcurl4
libssl3t64|libssl3
ffmpeg
"

if [ -t 1 ]; then
    B=$(printf '\033[1m'); R=$(printf '\033[31m'); G=$(printf '\033[32m')
    Y=$(printf '\033[33m'); D=$(printf '\033[2m'); N=$(printf '\033[0m')
else
    B=''; R=''; G=''; Y=''; D=''; N=''
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
warn() { printf '%s!%s   %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "this installer needs root. Re-run it as:
    curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh"
    fi
}

detect_arch() {
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)  ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) die "unsupported architecture '$machine'. Prebuilt releases cover x86_64 and
       aarch64; for anything else, build from source:
       https://github.com/$REPO/blob/main/docs/linux.md#build-from-source" ;;
    esac
}

require_linux_and_systemd() {
    [ "$(uname -s)" = "Linux" ] || die "this installer is for Linux. On macOS, download the .dmg:
       https://github.com/$REPO/releases"
    if ! [ -d /run/systemd/system ]; then
        die "systemd is not running (no /run/systemd/system), so there is no service
       to install into. Run the daemon directly instead — see
       https://github.com/$REPO/blob/main/docs/linux.md#without-systemd"
    fi
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

# `chown -R` follows a symlink NAMED on argv (-h covers only links inside the tree): ~/downloads -> /etc re-owns /etc.
safe_chown_tree() {
    target=$1
    if [ -L "$target" ]; then
        die "$target is a symbolic link. Refusing to change ownership through it —
       a link here can redirect the recursion at any directory on the machine.
       Point this at a real directory instead."
    fi
    chown -Rh "$SERVICE_USER:$SERVICE_USER" "$target"
}

# LC_ALL=C: "Candidate:" is translated, and a localised apt makes every package read as absent.
package_exists() {
    candidate=$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | sed -n 's/^  Candidate: //p' | head -1)
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

first_available() {
    saved_ifs=$IFS
    IFS='|'
    for name in $1; do
        if package_exists "$name"; then
            IFS=$saved_ifs
            printf '%s' "$name"
            return 0
        fi
    done
    IFS=$saved_ifs
    return 1
}

install_dependencies() {
    if [ "${GOEL_SKIP_DEPS:-}" = "1" ]; then
        say "${D}Skipping dependency install (GOEL_SKIP_DEPS=1).${N}"
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "not an apt-based distribution, so dependencies were not installed."
        warn "Install the equivalents of libssh2, libcurl, OpenSSL 3 and ffmpeg with your"
        warn "package manager. The install continues, and the library check after"
        warn "unpacking will name anything that is actually missing."
        return 0
    fi
    step "Installing runtime libraries"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || \
        warn "apt-get update failed; continuing with the package lists already present."

    # Resolve to concrete names first: one unknown package fails the whole `apt-get install` transaction.
    resolved=""
    missing=""
    # shellcheck disable=SC2086  # deliberate word splitting: one dependency per line
    for alternatives in $DEPENDENCY_ALTERNATIVES; do
        if chosen=$(first_available "$alternatives"); then
            resolved="$resolved $chosen"
        else
            missing="$missing $alternatives"
        fi
    done
    if [ -n "$missing" ]; then
        warn "no package found for:$missing"
        warn "The install continues; the library check below will say whether it matters."
    fi
    if [ -n "$resolved" ]; then
        say "    ${D}installing:${resolved# }${N}"
        # shellcheck disable=SC2086  # deliberate word splitting: a list of packages
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $resolved; then
            warn "apt could not install every package. The library check below will say"
            warn "whether the daemon can actually run."
        fi
    fi
}

LIBS_MISSING=0
verify_libraries() {
    command -v ldd >/dev/null 2>&1 || return 0
    step "Checking shared libraries"
    unresolved=$(
        for binary in "$INSTALL_ROOT/bin/GoelDaemon" "$INSTALL_ROOT/bin/goel"; do
            LD_LIBRARY_PATH="$INSTALL_ROOT/lib" ldd "$binary" 2>/dev/null
        done | grep 'not found' | awk '{print $1}' | sort -u || true
    )
    if [ -z "$unresolved" ]; then
        say "    ${G}ok${N} ${D}all resolved${N}"
        return 0
    fi
    warn "Goel° is missing shared libraries and will not run:"
    # shellcheck disable=SC2086  # deliberate word splitting: one library per line
    for lib in $unresolved; do warn "    $lib"; done
    warn ""
    warn "Find the package that provides one with:"
    warn "    apt-file search <library>      # apt install apt-file first"
    warn "then install it and re-run this installer."
    LIBS_MISSING=1
}

resolve_version() {
    if [ -n "${GOEL_VERSION:-}" ]; then
        VERSION="${GOEL_VERSION#v}"
        return 0
    fi
    step "Finding the latest release"
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
        | head -1)
    [ -n "$VERSION" ] || die "couldn't determine the latest version from the GitHub API.
       Either the API is rate-limiting this address, or no Linux release is
       published yet. Pick one explicitly with:
           curl -fsSL https://goel.vinitk.dev/install.sh | sudo GOEL_VERSION=x.y.z sh
       Releases: https://github.com/$REPO/releases"
}

fetch_tarball() {
    TARBALL="$WORK/goel.tar.gz"
    if [ -n "${GOEL_TARBALL:-}" ]; then
        [ -f "$GOEL_TARBALL" ] || die "GOEL_TARBALL=$GOEL_TARBALL does not exist."
        step "Using local tarball $GOEL_TARBALL"
        cp "$GOEL_TARBALL" "$TARBALL"
        return 0
    fi
    name="goel-daemon-${VERSION}-linux-${ARCH}.tar.gz"
    url="https://github.com/$REPO/releases/download/v${VERSION}/${name}"
    step "Downloading $name"
    curl -fSL --progress-bar "$url" -o "$TARBALL" || die "download failed: $url
       If that version has no Linux build for $ARCH, check what is published at
       https://github.com/$REPO/releases"

    # Hard failure, not a warning: whoever can tamper with the tarball can equally make the .sha256 fetch fail.
    step "Verifying checksum"
    if curl -fsSL "${url}.sha256" -o "$TARBALL.sha256" 2>/dev/null; then
        expected=$(cut -d' ' -f1 < "$TARBALL.sha256" | tr -d '\r\n')
        actual=$(sha256sum "$TARBALL" | cut -d' ' -f1)
        if [ "$expected" != "$actual" ]; then
            die "checksum mismatch — refusing to install.
       expected $expected
       got      $actual
       Delete nothing and report this: https://github.com/$REPO/issues"
        fi
        say "    ${G}ok${N} ${D}$actual${N}"
    elif [ "${GOEL_INSECURE:-}" = "1" ]; then
        warn "no published .sha256, and GOEL_INSECURE=1 — installing UNVERIFIED."
    else
        die "no published checksum for v${VERSION} (${name}.sha256 could not be
       fetched), so this download cannot be verified — and this installer runs as
       root. Refusing.

       If the release genuinely has no checksum, that is a release bug worth
       reporting: https://github.com/$REPO/issues
       To install anyway, knowing the risk:
           curl -fsSL https://goel.vinitk.dev/install.sh | sudo GOEL_INSECURE=1 sh"
    fi
}

# tar does NOT confine members to `-C`: a member named ../../etc/cron.d/x lands there.
verify_tarball_members() {
    escapes=$(tar -tzf "$1" | grep -E '(^/|(^|/)\.\.(/|$))' || true)
    [ -z "$escapes" ] || die "this tarball contains paths that escape the directory it
       unpacks into, which a Goel° release never does. Refusing to extract it:
$escapes"
    # First char of tar -tv's mode column is the type: l = symlink, h = hardlink.
    links=$(tar -tvzf "$1" | grep -E '^[lh]' || true)
    [ -z "$links" ] || die "this tarball contains links, which a Goel° release never
       does. Refusing to extract it:
$links"
}

# Install
# ---------------------------------------------------------------------------
create_user() {
    # Explicit: `useradd --system` creates a matching group only where login.defs sets USERGROUPS_ENAB yes.
    if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
        step "Creating the $SERVICE_USER system group"
        groupadd --system "$SERVICE_USER" || die "couldn't create the $SERVICE_USER group."
    fi
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi
    step "Creating the $SERVICE_USER system user"
    # No login shell and no home: this account owns a socket and a directory, not a way onto the machine.
    useradd --system --no-create-home --home-dir "$STATE_DIR" \
            --gid "$SERVICE_USER" --shell /usr/sbin/nologin "$SERVICE_USER" \
        || die "couldn't create the $SERVICE_USER user."
}

unpack() {
    step "Unpacking into $INSTALL_ROOT"
    verify_tarball_members "$TARBALL"
    staging="$WORK/unpacked"
    mkdir -p "$staging"
    tar -xzf "$TARBALL" -C "$staging" || die "the tarball could not be extracted."
    inner=$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -n "$inner" ] || die "unexpected tarball layout: no top-level directory."
    [ -x "$inner/bin/GoelDaemon" ] || die "unexpected tarball layout: no bin/GoelDaemon."

    # Swap, don't overwrite: extracting over a live install leaves a half-old tree if it fails partway.
    rm -rf "$INSTALL_ROOT.new"
    mv "$inner" "$INSTALL_ROOT.new"
    if [ -e "$INSTALL_ROOT" ]; then
        rm -rf "$INSTALL_ROOT.old"
        mv "$INSTALL_ROOT" "$INSTALL_ROOT.old"
    fi
    mv "$INSTALL_ROOT.new" "$INSTALL_ROOT"
    rm -rf "$INSTALL_ROOT.old"

    chmod 0755 "$INSTALL_ROOT/run.sh" "$INSTALL_ROOT/bin/"*

    # Do not overwrite: the tarball knows its own version, else a GOEL_TARBALL install reports "local".
    if [ -s "$INSTALL_ROOT/VERSION" ]; then
        VERSION=$(tr -d ' \r\n' < "$INSTALL_ROOT/VERSION")
    else
        printf '%s\n' "$VERSION" > "$INSTALL_ROOT/VERSION"
    fi

    [ -x "$INSTALL_ROOT/bin/goel" ] \
        || die "this tarball has no bin/goel — it predates the CLI. Install 1.0.4 or later."

    # A wrapper, not a symlink: /opt/goel/lib is on no system library path, so a symlink cannot load.
    cat > "$CLI_LINK" <<WRAPPER
#!/bin/sh
# Installed by Goel°'s installer. Puts the bundled Swift runtime on the library
# path, then runs the CLI. Removed by \`goel uninstall\`.
LD_LIBRARY_PATH="$INSTALL_ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$INSTALL_ROOT/bin/goel" "\$@"
WRAPPER
    chmod 0755 "$CLI_LINK"
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 0755 "$CONFIG_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        step "Keeping your existing $CONFIG_FILE"
        UPGRADED=1
        return 0
    fi
    step "Writing $CONFIG_FILE"
    UPGRADED=0
    # Random on first install: a default password would be shared by every Goel° server on the internet.
    GENERATED_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)
    generated_token=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [ -n "$GENERATED_PASSWORD" ] || die "couldn't generate a password from /dev/urandom."
    [ -n "$generated_token" ] || die "couldn't generate a token from /dev/urandom."

    # Restore the CALLER's umask, not a hardcoded 022: install_unit creates directories with it.
    saved_umask=$(umask)
    umask 077
    cat > "$CONFIG_FILE" <<CONFIG
# Goel° daemon configuration.
#
# systemd reads this as the service's environment (EnvironmentFile=), so these are
# plain KEY=value lines — no shell syntax, no expansion. Edit by hand if you like,
# then \`sudo systemctl restart goel\`, or let the CLI do both:
#
#     sudo goel config set port 9090
#     sudo goel config           # list everything
#
# This file is 0600 and root-only because GOEL_PASSWORD below is in plaintext.
# systemd reads it as root before dropping to the goel user, so nothing else
# needs access.

GOEL_PORT=${GOEL_PORT:-8080}

# false = loopback only (safe default). true also needs a password set, or the
# daemon refuses the LAN bind and quietly stays on 127.0.0.1.
GOEL_ALLOW_LAN=${GOEL_LAN:-false}

GOEL_REQUIRE_AUTH=true
GOEL_USERNAME=admin
GOEL_PASSWORD=$GENERATED_PASSWORD
GOEL_TOKEN=$generated_token

GOEL_SAVE_DIR=${GOEL_SAVE_DIR:-$STATE_DIR/downloads}
GOEL_DB=$STATE_DIR/queue.sqlite

# Network aggregation — split each download across several interfaces.
# Left unset on purpose: unset means "whatever the web portal last saved", so a
# change made there survives a restart. Setting it here makes this file the
# authority and the portal's toggle becomes temporary. \`goel adapters\` lists
# what this machine has; splitting only helps when each interface has its own
# upstream link.
#
#     GOEL_AGGREGATION=true
#     GOEL_AGGREGATION_ADAPTERS=eth0,wlan0   # empty = every eligible interface
#     GOEL_AGGREGATION_STREAMS=2             # connections per interface, 1-8
CONFIG
    umask "$saved_umask"
    chmod 0600 "$CONFIG_FILE"
}

install_unit() {
    step "Installing the systemd service"
    [ -f "$INSTALL_ROOT/systemd/goel.service" ] \
        || die "the tarball is missing systemd/goel.service."
    install -m 0644 "$INSTALL_ROOT/systemd/goel.service" "$UNIT_FILE"
    mkdir -p "$DROPIN_DIR" "$STATE_DIR"
    safe_chown_tree "$STATE_DIR"
    systemctl daemon-reload

    # Delegated to `goel config sync`: deriving writable paths from $GOEL_SAVE_DIR broke upgrades that kept a config.
    if [ "$LIBS_MISSING" = "1" ]; then
        warn "skipping the writable-paths drop-in: the CLI cannot run yet (see above)."
        return 0
    fi
    step "Configuring writable paths"
    LD_LIBRARY_PATH="$INSTALL_ROOT/lib" "$INSTALL_ROOT/bin/goel" config sync \
        || die "\`goel config sync\` failed, so the service has no writable paths and
       every download would fail. The install is otherwise complete — fix the
       reported problem and run:  sudo goel config sync"
}

start_service() {
    if [ "$LIBS_MISSING" = "1" ]; then
        say "${D}Not starting: the shared libraries above have to be installed first.${N}"
        STARTED=0
        return 0
    fi
    if [ "${GOEL_NO_START:-}" = "1" ]; then
        say "${D}Not starting the service (GOEL_NO_START=1). \`sudo goel start\` when ready.${N}"
        STARTED=0
        return 0
    fi
    step "Starting the service"
    # Keep systemctl's stderr: a malformed unit fails before the daemon runs, so the journal is empty.
    enable_output=$(systemctl enable --now goel 2>&1) || true
    # `--now` leaves an already-running service alone, so an upgrade would keep running the replaced binary.
    restart_output=$(systemctl restart goel 2>&1) || true
    [ -z "$restart_output" ] || enable_output="$enable_output$restart_output"
    i=0
    while [ "$i" -lt 30 ]; do
        state=$(systemctl is-active goel 2>/dev/null || true)
        [ "$state" = "activating" ] || break
        i=$((i + 1))
        sleep 0.2
    done
    state=$(systemctl is-active goel 2>/dev/null || true)
    if [ "$state" != "active" ]; then
        warn "the service did not come up (state: ${state:-unknown})."
        [ -z "$enable_output" ] || warn "systemd said: $enable_output"
        warn "Diagnose it with:  sudo goel doctor    and    sudo goel logs"
        STARTED=0
        return 0
    fi
    if ! systemctl is-enabled goel >/dev/null 2>&1; then
        warn "the service is running but is NOT enabled, so it will not come back"
        warn "after a reboot. Enable it with:  sudo goel enable"
        [ -z "$enable_output" ] || warn "systemd said: $enable_output"
    fi
    STARTED=1
}

summary() {
    port=$(sed -n 's/^GOEL_PORT=//p' "$CONFIG_FILE" | tail -1)
    port=${port:-8080}
    lan=$(sed -n 's/^GOEL_ALLOW_LAN=//p' "$CONFIG_FILE" | tail -1)
    say ""
    if [ "${STARTED:-0}" = "1" ]; then
        printf '%sGoel° %s is installed and running.%s\n' "$G$B" "$VERSION" "$N"
    else
        printf '%sGoel° %s is installed.%s\n' "$B" "$VERSION" "$N"
    fi
    say ""
    say "  ${B}Portal${N}    http://127.0.0.1:$port/"
    case "$lan" in
        true|yes|1|on)
            address=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -1 || true)
            [ -n "$address" ] && say "            http://$address:$port/   ${D}(from the LAN)${N}"
            ;;
    esac
    # Default 1 (upgrade): the other branch expands $GENERATED_PASSWORD, which under `set -u` aborts.
    if [ "${UPGRADED:-1}" = "0" ]; then
        say ""
        say "  ${B}Username${N}  admin"
        say "  ${B}Password${N}  $GENERATED_PASSWORD"
        say ""
        say "  ${D}Generated for this machine, and stored in $CONFIG_FILE.${N}"
        say "  ${D}Change it with:  sudo goel config set password '<new password>'${N}"
    fi
    say ""
    say "  ${B}Next${N}      sudo goel status        ${D}what it is doing${N}"
    say "            sudo goel add <url>    ${D}queue a download${N}"
    say "            sudo goel doctor       ${D}check the install${N}"
    say "            sudo goel help         ${D}everything else${N}"
    case "$lan" in
        true|yes|1|on)
            say ""
            warn "The portal is exposed to the network over plain HTTP: the password and"
            warn "the API token cross it unencrypted. Put nginx or caddy in front for TLS"
            warn "before using this anywhere untrusted."
            ;;
    esac
    say ""
}

main() {
    require_root
    require_linux_and_systemd
    detect_arch
    need_tool curl
    need_tool tar
    need_tool sha256sum
    need_tool useradd
    need_tool groupadd
    need_tool install

    WORK=$(mktemp -d) || die "couldn't create a temporary directory."
    # A trap does not exit on its own in POSIX sh: without these, Ctrl-C deletes $WORK and installs on.
    trap 'rm -rf "$WORK"' EXIT
    trap 'rm -rf "$WORK"; exit 130' INT
    trap 'rm -rf "$WORK"; exit 143' TERM

    printf '%sGoel° for Linux%s — headless download daemon\n\n' "$B" "$N"

    install_dependencies
    if [ -z "${GOEL_TARBALL:-}" ]; then
        resolve_version
    else
        VERSION="${GOEL_VERSION:-local}"
    fi
    fetch_tarball
    create_user
    unpack
    verify_libraries
    write_config
    install_unit
    start_service
    summary
}

main "$@"
