# Deploying Goel° Downloader in a managed fleet

This directory contains what an IT department needs to roll the app out to more
than one Mac: a sample configuration profile (`goel.mobileconfig`) and the notes
below.

Two things are worth saying up front, because they change how you evaluate this
software:

* **There is no licence server, no activation, no trial clock and no phone-home.**
  The app behaves identically on every machine whether or not it is managed. A
  managed profile can only pin values a user could have set themselves — it can
  never disable the app or lock anyone out.
* **Commercial and enterprise use requires a paid licence** from the owner. The
  source is available and personal use is free, but deploying this inside a
  company is commercial use. Compliance is on the honour system; nothing in the
  software enforces it. Get in touch before you deploy.

---

## 1. Managed preferences

The app reads its managed settings from the preference domain
**`com.goel.downloader`**, so a configuration profile delivered by any MDM
works: the value lands in `/Library/Managed Preferences/`, which is where the
app reads it from (falling back to `CFPreferencesCopyAppValue` for hosts that
put it elsewhere).

**A key is enforced if and only if it arrives *forced* from a configuration
profile.** That is an enforcement contract, not a UI hint. The preference domain
is the app's own bundle identifier, so its search chain ends in a plist the user
can write — a value found there is a seeded default the user still owns, and the
app will not treat it as policy. Forced keys are also the ones the Settings UI
shows as locked, so the administrator's choices are visible rather than silently
reverting the user's edits.

`goel.mobileconfig` demonstrates every supported key. Delete the ones you do not
want to control; an absent key is left entirely to the user.

### Supported keys

| Key | Type | Meaning |
| --- | --- | --- |
| `defaultSaveDirectory` | string | Absolute path new downloads are saved to. Must already exist and be writable. |
| `defaultFolderRule` | string | `automatic` \| `byType` \| `bySource` \| `fixed`. Pair `fixed` with `defaultSaveDirectory` to pin everything to one location. |
| `proxyMode` | string | `none` \| `system` \| `manual`. |
| `proxyType` | string | `http` \| `socks5`. |
| `proxyHost` | string | Manual proxy host. |
| `proxyPort` | integer | Manual proxy port. |
| `proxyAllProtocols` | bool | Route FTP/SFTP/BitTorrent through the manual proxy too. |
| `selectedProfileName` | string | Traffic profile the app starts on (`Low`, `Medium`, `High`, or a user-created name). |
| `speedLimitEnabled` | bool | Whether byte/sec caps apply at all. |
| `maxDownloadBytesPerSec` | integer | Fleet-wide download ceiling in **bytes** per second. |
| `maxUploadBytesPerSec` | integer | Fleet-wide upload ceiling in **bytes** per second. |
| `remoteAccessEnabled` | bool | Master switch for the built-in web portal / JSON API. |
| `remoteAllowLAN` | bool | Listen on the LAN instead of loopback only. |
| `remoteRequireAuth` | bool | Require a portal sign-in. Leave `true`. |
| `remoteReadOnly` | bool | Portal can view and stream but not change anything. |
| `remoteTLSEnabled` | bool | Serve the portal over HTTPS. |
| `remoteTLSIdentityPath` | string | Path to the PKCS#12 bundle used for that. |
| `remoteTrustedHeaderAuthEnabled` | bool | Accept an identity asserted by a trusted upstream proxy. |
| `remoteTrustedHeaderName` | string | Which header carries it, e.g. `X-Forwarded-User`. |
| `remoteTrustedProxies` | array of string | Addresses allowed to assert it. Literal IPs or IPv4 CIDR. |
| `autoCheckUpdates` | bool | Let the app check for new releases. |
| `updateFeedURL` | string | Point the updater at an internal appcast. |
| `auditLogEnabled` | bool | Write the local audit log. |
| `auditLogDirectory` | string | Where it is written. Empty = the app's Application Support folder. |
| `auditLogRetentionDays` | integer | Delete rotated files older than this. `0` = never. |
| `auditLogKeepFiles` | integer | Rotated files kept beside the live one. |
| `auditLogMaxFileMegabytes` | integer | Rotate the live file at this size. |

### Notes on the bandwidth ceilings

`maxDownloadBytesPerSec` and `maxUploadBytesPerSec` are applied as a **clamp
across every traffic profile**, not as a value assigned to the current one. A
user who switches from Medium to High still cannot exceed the ceiling. Setting
either ceiling also forces the speed limiter on, because the caps are ignored
while it is off.

---

## 2. Deploying the profile

### Jamf Pro

1. **Computers → Configuration Profiles → New**.
2. Add an **Application & Custom Settings** payload.
3. Choose *Upload* (not *Jamf Applications*), set the **Preference Domain** to
   `com.goel.downloader`, and paste the contents of the inner `<dict>` from
   `goel.mobileconfig` (the payload dict, not the whole file).
   *Alternatively* upload `goel.mobileconfig` whole under **Computers →
   Configuration Profiles → Upload**.
4. Scope it, and set **Level: Computer Level**.

### Kandji

1. **Library → Add New → Custom Profile**.
2. Upload `goel.mobileconfig` as-is.
3. Assign it to a Blueprint.

### Microsoft Intune

1. **Devices → macOS → Configuration profiles → Create profile**.
2. Profile type: **Templates → Preference file** if you are shipping a single
   domain, with preference domain `com.goel.downloader`; or **Custom** and
   upload `goel.mobileconfig` whole.
3. Assign to a device group. Intune applies macOS custom profiles at the device
   level, which matches `PayloadScope: System` in the sample.

### Munki

Ship the profile as a `configuration_profile` item:

```
munkiimport --nopkgupload Deploy/goel.mobileconfig
```

and add it to a manifest as a managed install.

### Testing by hand

```bash
# Install (macOS 11+ requires manual approval in System Settings → Profiles)
sudo profiles install -type configuration -path Deploy/goel.mobileconfig

# Confirm the app will see it
defaults read /Library/Managed\ Preferences/com.goel.downloader.plist

# Remove
sudo profiles remove -identifier com.goel.downloader.managed
```

### `defaults write` is not a shortcut

Installing the profile is the only supported way to test a key. `defaults write
com.goel.downloader …` has **no effect on policy**, deliberately: that domain is
writable by the logged-in user, so honouring a value from it would let any local
process appoint itself the IT department — pointing every download through a
proxy of its choosing, redirecting the save folder, and switching off the audit
log that would have recorded it. The app enforces forced values only.

Verify what the app will actually see with the `defaults read` line above; it
reads `/Library/Managed Preferences/`, which only root can write.

---

## 3. The web portal in an enterprise network

The portal is off by default and binds `127.0.0.1` only. It refuses to bind to
the LAN unless sign-in is required **and** a portal password has actually been
set, so a half-configured portal cannot be exposed by accident.

### Brute-force protection

Failed sign-ins are counted **per client IP address** (taken from the socket, not
from a header). After `remoteLoginMaxAttempts` misses — five by default — that
address is locked out for `remoteLoginBackoffSeconds`, doubling on each further
miss up to fifteen minutes. A correct password clears the record immediately.
The penalty follows the guessing address, so one attacker cannot lock your users
out.

### TLS

To serve the portal over HTTPS you supply a PKCS#12 bundle. macOS cannot build
one from PEM files on its own, so create it with `openssl`:

```bash
# 1. A self-signed certificate valid for two years, for the machine's own name.
openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
  -keyout portal.key -out portal.crt \
  -subj "/CN=mac-1234.corp.example.com" \
  -addext "subjectAltName=DNS:mac-1234.corp.example.com,IP:10.20.1.34"

# 2. Bundle key + certificate into a .p12.
openssl pkcs12 -export -inkey portal.key -in portal.crt -out portal.p12

# 3. Install it somewhere only root can write.
sudo install -m 0644 -o root -g wheel portal.p12 \
  "/Library/Application Support/Goel/portal.p12"
```

If your organisation has an internal CA, issue the certificate from it instead
of step 1 — then browsers trust the portal without a warning, because the CA is
already in the fleet's trust store.

The `.p12` passphrase is read from the **`GOEL_PORTAL_TLS_PASSPHRASE`
environment variable**, never from a settings file. This is deliberate: the
settings file is plain JSON that ends up in backups, exports and support emails.
Put the passphrase in the launchd job:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>GOEL_PORTAL_TLS_PASSPHRASE</key>
    <string>…</string>
</dict>
```

If TLS is enabled and the identity cannot be loaded, **the portal does not
start**. It never falls back to cleartext.

> On macOS 14 the PKCS#12 import lands in the user's login keychain (the
> in-memory-only import option is macOS 15+). Use a certificate issued for this
> purpose rather than sharing one you use elsewhere.

### Single sign-on via a trusted header

Implementing SAML or OIDC inside a download manager would be disproportionate.
Instead the portal can trust an identity that an upstream reverse proxy has
already verified — which is how Cloudflare Access, Authelia, oauth2-proxy,
Pomerium and most SSO-aware ingresses expose an internal app. That covers the
overwhelming majority of "it must use our SSO" requirements.

```
remoteTrustedHeaderAuthEnabled = true
remoteTrustedHeaderName        = X-Forwarded-User        (or Remote-User,
                                 Cf-Access-Authenticated-User-Email, …)
remoteTrustedProxies           = [ 127.0.0.1, 10.20.0.0/16 ]
```

Plus a shared secret, which lives in the environment rather than in settings for
the same reason as the TLS passphrase — it is a credential, and the settings file
ends up in backups and support emails:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>GOEL_PORTAL_PROXY_SECRET</key>
    <string>…</string>
</dict>
```

(on Linux, an `EnvironmentFile=` entry in the systemd unit). The proxy must send
that same value in the `X-Goel-Proxy-Secret` header on every forwarded request,
alongside the identity header. In nginx:

```nginx
proxy_set_header Host                $host;                 # or X-Forwarded-Host
proxy_set_header X-Forwarded-User    $authenticated_user;   # from your SSO step
proxy_set_header X-Goel-Proxy-Secret "…";                   # == the variable above
```

The secret header's name is fixed, not configurable: the name is not the
discriminator, the secret is, and one less knob is one less way to misconfigure
an authentication path.

The `Host` line is not optional. Every mutating request is checked for a
cross-site `Origin`, and the portal compares it against `Host` (falling back to
`X-Forwarded-Host`). nginx's default `proxy_pass` rewrites `Host` to the upstream
address, so without one of those two headers a legitimate browser request from
your public hostname looks like a cross-site write and is refused with 403.

**Read this before enabling it.** A blindly-trusted header is a complete
authentication bypass: anyone who can reach the port simply sends the header
themselves. Four rules make it safe, and the app enforces all four:

1. It is **off by default**.
2. It is ignored while `remoteTrustedProxies` is empty. An empty list means
   "trust nobody", never "trust everybody".
3. The address checked is the **socket peer address from the kernel**, not
   `X-Forwarded-For`. A client cannot forge it.
4. The request must carry `X-Goel-Proxy-Secret` matching
   `GOEL_PORTAL_PROXY_SECRET`, compared in constant time. An unset or empty
   variable disables header SSO outright — the identity header is never honoured
   without it.

Rule 4 is what makes the deployment below safe at all. Rule 3 only discriminates
when the proxy sits on a *different* host; with the portal on loopback and the
proxy on the same box every local process shares the peer address `127.0.0.1`, so
any local user could `curl` the identity header in and become whoever they liked.
The secret is the discriminator the proxy holds and they do not.

Deploy the proxy so that it is the only thing that can reach the portal's port —
ideally by leaving the portal on loopback and running the proxy on the same
machine.

### On Linux (the headless daemon)

The Linux daemon links SwiftNIO but not NIOSSL, so it cannot terminate TLS
itself; if `remoteTLSEnabled` is set it logs the reason and refuses to start
rather than serving cleartext. Terminate TLS at nginx, Caddy or Traefik in front
of a loopback bind — which is how these machines are usually deployed anyway.

The daemon also has no CFPreferences, so it reads the same key set from a flat
JSON file:

```bash
sudo mkdir -p /etc/goel
sudo tee /etc/goel/managed-policy.json >/dev/null <<'JSON'
{
  "defaultSaveDirectory": "/srv/downloads",
  "maxDownloadBytesPerSec": 5242880,
  "auditLogEnabled": true,
  "auditLogDirectory": "/var/log/goel"
}
JSON
```

Override the path with the `GOEL_MANAGED_POLICY` environment variable. Every key
present in the file is treated as forced — a file placed in `/etc` by root is the
administrator speaking.

That authority is the file's permissions and nothing else, so it is checked: **a
group- or world-writable policy file is refused**, logged, and the daemon runs
unmanaged rather than trusting a file any local user could rewrite. `sudo tee`
above respects your umask, so set the mode explicitly:

```bash
sudo chmod 0644 /etc/goel/managed-policy.json
```

A file that exists but does not parse is also refused and logged — the daemon
still starts, but a typo will not silently cost you the whole policy.

---

## 4. The audit log

Turn it on with `auditLogEnabled`. It writes JSON Lines — one self-contained
JSON object per line — to `auditLogDirectory` (or the app's Application Support
folder), rotating at `auditLogMaxFileMegabytes` and pruning by both
`auditLogKeepFiles` and `auditLogRetentionDays`.

One line per download added, completed or failed:

```json
{"action":"completed","bytes":184549376,"destination":"/Users/Shared/Downloads","host":"releases.example.com","kind":"http","scheme":"https","taskID":"7C1F…","timestamp":"2026-03-04T09:41:22Z","user":"a.patel"}
```

**What is deliberately not in it:** the full URL. Only the *host* is recorded —
never the path, the query string, the fragment, or any `user:password@` in the
URL. A pre-signed download URL is a bearer credential, and an audit file that
leaked one would be worse than no audit file at all. Magnet links are recorded
as the literal string `magnet`, because the info-hash identifies the content.
Failure records carry a stable token such as `http-403` or `diskFull`, never the
server's message (which routinely echoes the URL back).

**This is a compliance record, not telemetry.** It is written to the machine's
own disk and stays there. Nothing in the app reads these files back, uploads
them, or includes them in a diagnostics export. If you want them centrally, ship
them yourself with whatever log collector you already run — the format is
designed for `jq`, Splunk and Elastic to ingest without a parser.

---

## 5. Verifying the "no telemetry" claim

The claim is that the app makes no network request the user did not ask for.
Two things make that checkable rather than something you have to take on trust:

* All logging goes through `Sources/GoelCore/Diagnostics/GoelLog.swift`, which
  has exactly two sinks: the local unified log on macOS and stderr elsewhere.
  Neither opens a socket.
* The audit log (`Sources/GoelCore/Enterprise/AuditLog.swift`) writes to disk
  and nothing else.

If `autoCheckUpdates` is left on, the updater contacts the release feed —
`updateFeedURL` if you set it, otherwise the vendor's public appcast. Set
`autoCheckUpdates` to `false` when your own patching process ships the app, and
the app makes no unsolicited outbound connection at all.
