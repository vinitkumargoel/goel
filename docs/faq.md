# FAQ

Licensing and procurement questions are answered on the
[commercial licensing page](https://goel.vinitk.dev/commercial) and in the
[compliance pack](compliance/). This page covers using the app.

---

## Licensing

### Is Goel° free?

For personal use, yes — permanently, with no feature limits and no trial clock. If an
organisation of any kind benefits from the use (a company, a government body, a school as
an institution, a non-profit with paid staff, or any MDM-managed fleet) a paid licence is
required. The licence is
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/).

### Will the app stop working if we don't pay?

No. There is no licence key, no activation server and no kill switch — the build a paying
enterprise runs is identical to the build a student runs. Compliance is honour-based.
That is deliberate and it will not change.

### Can we evaluate it at work first?

Yes, with no time limit. Evaluation is fine; running it in production at an organisation
is what needs a licence.

---

## Privacy and network behaviour

### Does Goel° collect any data about me?

No. There is no analytics, no crash reporting, no usage counter and no licence check-in.
Nothing is transmitted about you, your queue, or your machine.

### Then what connections does it make?

Three kinds, all of them things you asked for:

1. **Your transfers** — directly from your machine to the server, peer or tracker in the
   source you added. Nothing is proxied through us.
2. **The update check** — a GitHub-Releases feed check on macOS, **off by default** with an empty
   feed URL, so it makes no request until you configure it in **Settings → Advanced**.
   (Sparkle is bundled but dormant: it only activates in a build whose `Info.plist` carries an
   appcast URL and public key, and no published release carries one yet.)
3. **The web portal**, if you enable it — served from your own machine to whoever you
   let reach it.

Leave the update check off — its default — and Goel° is silent until you add a download.

### Can it run air-gapped?

Yes. Leave the update check off — it starts off — and it makes no connection it was not
explicitly told to make.

### Where are my passwords stored?

In the macOS Keychain. The web-portal password is additionally stored only as a salted
PBKDF2-HMAC-SHA256 digest (210,000 iterations), so a leaked settings file does not
disclose it.

---

## Downloads

### How does it know which protocol to use?

From the source itself. An `https://` URL, an `ftp://` URL, an `sftp://` path, a magnet
URI, a `.torrent` file and an `.m3u8` playlist all get routed to the right engine
automatically — you add them the same way and they sit in the same queue.

### Does it resume interrupted downloads?

Yes, including across app restarts and reboots. Queue state and partial progress are
persisted, so a download that was 80% done comes back 80% done.

### Can I download only some files from a torrent?

Yes. Open the task's **Files** tab and set per-file priority: Skip, Low, Normal or High.
Skipped files are not written to disk at all.

### Can I watch a video while it downloads?

Yes, if the download is sequential or already complete. Enable **sequential mode** on the
task, then use the stream link from the web portal. Torrents downloaded in the default
rarest-first order are not streamable until they finish, because the bytes do not arrive
in playback order.

### Does it support browser integration?

Yes, but it is side-loaded rather than installed from a store. A WebExtension ships inside
the app bundle (`Resources/BrowserExtension`); **Settings → Browser** reveals the folder and
installs the native-messaging helper. What each browser does with it differs:

- **Chromium family** — Chrome, Edge, Brave, Chromium, Vivaldi, Arc. `chrome://extensions` →
  Developer mode → **Load unpacked** → that folder. It stays loaded across restarts.
- **Firefox** — `about:debugging` → **Load Temporary Add-on**. Firefox discards temporary
  add-ons when it quits, so this has to be repeated after every Firefox restart. A permanent
  install needs a Mozilla-signed `.xpi`, which is not published yet.
- **Safari** — the extension is an app extension inside the bundle, so Safari finds it once
  the app is in `/Applications` (quit and reopen Safari once). Enable **Goel° Capture** in
  Safari's extension list. An unsigned or ad-hoc build additionally needs Safari →
  Develop → **Allow Unsigned Extensions**, which resets each session.

### Are there speed limits and scheduling?

Yes, plus a scheduler for time-of-day rules. Read the limits precisely, though: the traffic
profile's cap is enforced **across all HTTP downloads together**, while FTP, SFTP and HLS
transfers each get their own limiter — so several of those running at once can exceed the
profile figure. Per-task limits apply to one task and stack in front of the shared cap.

---

## The web portal

### Is the portal safe to expose to the internet?

Treat it as you would any admin panel. It uses constant-time token comparison,
HttpOnly + SameSite=Strict session cookies, PBKDF2-hashed passwords, login lockout after
five failed attempts, a strict Content-Security-Policy and `X-Frame-Options: DENY`. It
does not do TLS itself — put it behind a reverse proxy or a VPN/Tailscale before exposing
it. Better still, don't expose it: bind to loopback and reach it over a tunnel.

### Can I let someone view the queue without letting them change it?

Yes — **read-only mode**. Every mutating route returns 403 while it is on; viewing and
media streaming still work.

### Can I script it?

Yes. Pass `Authorization: Bearer <token>` or `?token=<token>` to the JSON API. See
[remote-api.md](remote-api.md) for all 14 routes.

---

## Platforms

### Is there a Windows version?

No, and none is planned. The app is macOS 14+ on Apple Silicon. `GoelDaemon` covers Linux
headlessly.

### Does it work on Intel Macs?

Builds are published for Apple Silicon. Building from source for Intel is possible — set
`GOEL_BREW_PREFIX=/usr/local` to link against an Intel Homebrew — but it is not a
supported binary target.

### What Linux distributions are supported?

Anything with a Swift 6.3 toolchain plus libtorrent-rasterbar, libssh2 and libcurl. Ubuntu
is the tested path. Note the SQLite snapshot requirement in
[getting-started.md](getting-started.md).

---

## Data and portability

### Where is my data kept?

Locally: the queue and history in a GRDB/SQLite database in the app's support directory,
credentials in the Keychain, downloaded files wherever you chose. No cloud, no account.

### Can I back up or migrate?

Yes — backups export as plain JSON files that you create and keep yourself. There is no
proprietary container.

### What happens to my downloads if I uninstall?

Downloaded files stay where they are; they are ordinary files. Removing the app removes
the app.
