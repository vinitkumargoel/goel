# The browser extension (Goel° Capture)

Goel° Capture sends downloads from your browser to Goel°. Two ways in:

- **Capture mode** — a toolbar toggle. While it is ON, every download the browser starts is
  cancelled in the browser and handed to Goel° instead.
- **Right-click** — **Download with Goel°** on any link, image, video or audio element,
  regardless of the toggle. This works in every supported browser.

Optionally, it can forward the browser's login cookies for that URL, which is what makes
downloads behind a sign-in work — paywalled files, private forums, university portals.
That is **off by default** and behind a permission you grant explicitly.

> **It is side-loaded, not installed from a store.** There is no Chrome Web Store or
> addons.mozilla.org listing, so the install is manual and Firefox's is temporary. This is
> the honest state of things, not a step you have missed. Safari is the exception: its copy
> is an app extension inside `Goel°.app` and needs no side-loading at all.

---

## Before you start

You need **Goel° installed in `/Applications`** (not run from `.build`). The extension
files and the Safari app extension both ride inside the app bundle.

The unpacked extension lives at:

```
/Applications/Goel°.app/Contents/MacOS/GoelDownloader_GoelApp.bundle/BrowserExtension
```

You never have to type that. **Settings ▸ Browser Integration ▸ Show Folder** reveals it in
Finder, and every step below refers to it as *the extension folder*.

---

## Step 1 — Install the messaging helper (Chromium and Firefox only)

Chromium-family browsers and Firefox talk to Goel° over **native messaging**, which needs a
small manifest inside each browser's own support directory. Safari does not use this at all —
skip to [Safari](#safari) if that is your browser.

1. Open **Goel° ▸ Settings ▸ Browser Integration**.
2. Click **Install Helper**.

It reports which browsers it configured, e.g. *"Helper installed for Chrome, Firefox"*.
Everything it writes is under your home directory — no admin password, nothing system-wide:

| File | Purpose |
|---|---|
| `~/Library/Application Support/GoelDownloader/native-messaging-host.sh` | Wrapper that relaunches Goel° in host mode (browsers can't pass arguments, so the script re-adds the flag) |
| `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.goeldownloader.host.json` | Chrome's pointer to that wrapper |
| …the same file under `Chromium/`, `BraveSoftware/Brave-Browser/`, `Microsoft Edge/`, `Vivaldi/`, `Arc/User Data/`, `Mozilla/` | One per browser found |

Two things follow from how this works, and both bite people:

- **A browser you have never launched gets nothing.** The helper only writes into support
  directories that already exist, so if it says *"No supported browsers found"*, open the
  browser once and click **Install Helper** again.
- **Moving `Goel°.app` breaks it.** The wrapper embeds the app's path. If you move or
  reinstall the app, click **Install Helper** once more to refresh it.

---

## Step 2 — Load the extension

### Chrome, Edge, Brave, Chromium, Vivaldi, Arc

1. Open `chrome://extensions` — on Edge `edge://extensions`, Brave `brave://extensions`,
   Vivaldi `vivaldi://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and select **the extension folder** (the folder itself, not a
   file inside it).

It stays loaded across browser restarts. The extension's ID is pinned to
`cibecdmaigobbnnollnoajkiioiaepda` by a `key` in its manifest, so it is the same ID wherever
you load it from — which is what lets the messaging helper authorise it in advance.

Chrome will show *"Load unpacked extension"* warnings on each startup; that is Developer
mode, not a problem with this extension.

### Firefox

Firefox **128 or later** is required (earlier versions can't grant the optional cookie
permission this extension uses).

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on…**.
3. Select **`manifest.json` inside the extension folder** — Firefox wants the manifest file,
   not the folder Chrome asks for.

**Firefox discards temporary add-ons when it quits**, so this has to be repeated after every
Firefox restart. A permanent install needs a Mozilla-signed `.xpi`, which is not published —
if that matters to you, use a Chromium-family browser.

### Safari

Safari needs no side-loading: the extension ships as an app extension
(`Goel°.app/Contents/PlugIns/GoelSafariExtension.appex`) and Safari discovers it from the
installed app.

1. Make sure `Goel°.app` is in `/Applications`, then **quit and reopen Safari once** so it
   registers the new extension.
2. Open **Safari ▸ Settings ▸ Extensions** — or click **Open Safari Extensions** in
   Goel° ▸ Settings ▸ Browser Integration, which jumps straight to the entry.
3. Tick **Goel° Capture**.
4. Safari will ask for permission on the sites you use it on. Choose **Always Allow on Every
   Website** if you want right-click capture to work everywhere without re-asking.

Two extra notes for Safari:

- **Unsigned or ad-hoc builds** (anything you built yourself rather than installed from a
  release `.dmg`) also need **Safari ▸ Develop ▸ Allow Unsigned Extensions**. That resets
  every time Safari restarts. If the Develop menu is missing, enable it in
  Safari ▸ Settings ▸ Advanced.
- **The extension won't appear at all** if the app is somewhere other than `/Applications` —
  Safari does not scan arbitrary locations for app extensions.

---

## What each browser can actually do

Safari is genuinely more limited, and it is better to know that now than to wonder why a
signed-in download came back as a login page.

| | Chrome / Edge / Brave / Chromium / Vivaldi / Arc | Firefox | Safari |
|---|---|---|---|
| Right-click → **Download with Goel°** | ✅ | ✅ | ✅ |
| Capture mode (toolbar toggle intercepts all downloads) | ✅ | ✅ | ❌ — Safari has no `downloads` API |
| Signed-in downloads (forwards cookies) | ✅ | ✅ | ❌ — see below |
| Survives a browser restart | ✅ | ❌ — reload each time | ✅ |
| Needs the messaging helper | ✅ | ✅ | ❌ |
| Adds without a confirmation prompt | ✅ | ✅ | ❌ — Safari captures open the add confirmation |

**Why Safari can't do cookies.** A Safari extension runs in a sandbox that cannot write
Goel°'s hand-off spool, so its only route to the app is opening a `goeldownloader://add?url=…`
URL. LaunchServices records the URLs it opens, and a session cookie must not be written
anywhere that gets logged — so the Safari handler refuses to carry one. Rather than offer the
option and then report that it failed, Safari simply doesn't show the two cookie affordances at
all: no **(stay signed in)** menu item, no **Send login cookies** checkbox. Use Chrome or
Firefox for downloads behind a login. Because that same route is the one a web page could
trigger, Safari captures also show Goel°'s add confirmation rather than queueing silently.

---

## Using it

**The toolbar button** toggles capture mode. `ON` on the badge means the next download the
browser starts goes to Goel° instead. If you don't see the button, pin it: Chrome hides
extension buttons behind the puzzle-piece icon by default.

**Right-click** any link, image, video or audio element:

- **Download with Goel°** — sends the URL.
- **Download with Goel° (stay signed in)** — sends the URL *and* your cookies for that site,
  asking permission the first time. Not shown in Safari, which cannot forward them.

**Right-click the toolbar button** for **Send login cookies with captured downloads** — the
same thing for capture mode rather than one-off sends. Also not shown in Safari.

### What the badge is telling you

| Badge | Meaning |
|---|---|
| `ON` (blue) | Capture mode is on |
| `✓` (blue) | Handed to Goel° |
| `!` (red) | Couldn't reach the app, or the app refused the link. Hover the button for which |
| `!` (amber) | Sent, but signed out — permission declined or revoked, or the app dropped the cookie. Also shown in Safari when you click the button, which can't capture downloads |

Hover the toolbar button for the full sentence. Nothing is ever shown as a system
notification, because that would need a `notifications` permission just to report failures.

The badge and tooltip are owned by the browser rather than by the extension, so they can
outlive the extension's own background worker. A warning is cleared on a timer where possible
and re-derived from scratch the next time the worker starts, so a stale `!` corrects itself
rather than persisting — but it can be a little slower to clear than the ten seconds intended.

---

## Signed-in downloads and your cookies

This is the only genuinely sensitive part of the feature, so here is exactly what happens.

- The `cookies` permission is **optional** and requested only when you first turn it on or
  choose *(stay signed in)*. You can install and use the extension without ever granting it.
  "Read your cookies" is the most alarming line in a browser permission dialog, and nobody
  should have to accept it to download a public file.
- Cookies are read with the browser's own `cookies.getAll({url})`, which honours
  Secure/SameSite/path rules for that exact URL and includes `HttpOnly` cookies — the session
  cookies a login actually depends on, which page JavaScript cannot see.
- Only cookies for **that URL's origin** are read, and only when the grant for that origin is
  still in place. Revoking it in the browser's settings takes effect immediately.
- They travel to the app over native messaging (a pipe, not a URL), are written to a `0600`
  file in a `0700` directory, are **deleted the moment the app reads them**, and are dropped
  entirely if they sit unread for more than **an hour** — the URL is still queued, just
  without the login. A stale session cookie is useless anyway.
- They are never logged, never saved with the task, and never echoed back to the browser.
  The app answers only *whether* cookies were accepted, never their names or values.
- Magnet links never carry cookies: there is no origin to scope them to.

---

## Troubleshooting

### Clicking "Download with Goel°" does nothing

Look at the toolbar badge, then hover it. A red `!` and *"can't reach the app"* means the
messaging helper is missing or stale:

1. Goel° ▸ Settings ▸ Browser Integration ▸ **Install Helper**.
2. **Fully quit and reopen the browser** — it caches host manifests at startup.

If it still fails, check the manifest exists and points somewhere real:

```sh
cat ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/com.goeldownloader.host.json
ls -l ~/Library/Application\ Support/GoelDownloader/native-messaging-host.sh
```

The `path` in that JSON must be the wrapper script, and the wrapper must point at the app's
current location. Re-running **Install Helper** rewrites both.

### "The app couldn't accept that link"

Goel° refuses captures that aren't plain web downloads. Only `http:`, `https:` and `magnet:`
are accepted, and the target must not be a loopback or link-local address — otherwise a web
page could use the extension to make Goel° fetch a service on your machine that was never
exposed to the browser. Add such a URL by hand through the Add sheet, where you are the one
choosing it.

### The extension vanished after restarting Firefox

Expected. Temporary add-ons do not persist — reload it from
`about:debugging#/runtime/this-firefox`. There is no fix short of a signed `.xpi`.

### Capture mode is ON but downloads still go to the browser

- **In Safari this never works** — it has no `downloads` API. The toolbar button says so when
  clicked; use the right-click menu.
- Elsewhere, only downloads *started after* you switched it on are captured, and only
  `http(s)` ones. A download the browser has already begun is left alone.

### A signed-in download comes back as a login page

- Amber `!` after the send: the cookies were dropped. In Safari that is by design (see
  above). Use Chrome or Firefox.
- Otherwise the cookie permission is probably not granted for that site. Choose *(stay signed
  in)* from the right-click menu and accept the prompt, or check the extension's site
  permissions in the browser.
- If Goel° was closed for more than an hour after the capture, the cookie expired out of the
  spool by design. Retry with the app open.

### Nothing works after moving or reinstalling the app

Re-run **Install Helper** (the wrapper embeds the old path), and in Chromium browsers remove
and re-**Load unpacked** the extension if you moved the folder it was loaded from.

### The extension is missing from Safari's list

The app must be in `/Applications`, and Safari must have been restarted since. Self-built
copies additionally need **Develop ▸ Allow Unsigned Extensions** every session.

### Nothing is available and Show Folder complains

You are running a development build. `Bundle.module` resolves to `.build/…`, not an installed
app, so the Safari extension isn't registered with the system. Package the app first:

```sh
Scripts/build_app.sh
```

---

## Removing it

- **Chromium** — `chrome://extensions` → **Remove**.
- **Firefox** — quit Firefox, or remove it from `about:debugging`.
- **Safari** — untick it in Safari ▸ Settings ▸ Extensions. It disappears entirely if you
  delete `Goel°.app`.
- **The messaging helper** — delete the manifests and the wrapper:

  ```sh
  rm -f ~/Library/Application\ Support/*/NativeMessagingHosts/com.goeldownloader.host.json
  rm -f ~/Library/Application\ Support/*/*/NativeMessagingHosts/com.goeldownloader.host.json
  rm -rf ~/Library/Application\ Support/GoelDownloader/native-messaging-host.sh
  ```

Nothing else is left behind: no launch agents, no system files, no receipts.

---

## Without the extension

All of these work with no extension at all, and are in
**Settings ▸ Browser Integration ▸ Without the extension**:

| Route | How |
|---|---|
| **URL scheme** | `goeldownloader://add?url=…` opens Goel° and queues the link, with a confirmation |
| **Bookmarklet** | Copy it from Settings, save as a bookmark; clicking sends the current page |
| **Services menu** | Select a link in any app → right-click → Services → **Download with Goel°** |
| **Drop basket** | ⌘⇧B — a small always-on-top target to drag links onto |

---

## For developers

The extension source is in the repository at `Sources/GoelApp/BrowserExtension/`:

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest. The `key` pins the Chrome ID; `browser_specific_settings.gecko.id` pins Firefox's |
| `background.js` | Everything: the toggle, context menus, cookie handling, native-messaging hand-off |
| `icons/` | 16/32/48/128 px toolbar and management-page icons |

It is declared as `.copy("BrowserExtension")` in `Package.swift`, so it lands verbatim in the
`GoelDownloader_GoelApp.bundle` resource bundle, and `Scripts/build_app.sh` copies the same
folder into the Safari `.appex`'s `Resources/`. **One set of files serves all three browser
families** — there is no separate Safari build to keep in sync.

The native half:

| Side | File |
|---|---|
| Chromium/Firefox host (stdio native messaging) | `Sources/GoelApp/NativeMessagingHost.swift` |
| Helper installer (writes host manifests) | `Sources/GoelApp/BrowserIntegrationService.swift` |
| Safari app extension handler | `SafariExtension/SafariWebExtensionHandler.swift` |

Working on it:

- **Iterating on the JS** — edit the copy in the repo, rebuild the app
  (`Scripts/build_app.sh`), then hit **Reload** on `chrome://extensions`. You can also load
  unpacked straight from `Sources/GoelApp/BrowserExtension/` and skip the rebuild — the ID is
  derived from the manifest's `key`, not the path, so the messaging helper still authorises
  it. Only Safari needs the rebuild, because its copy has to be inside the signed `.appex`.
- **Changing the `key`** changes the Chrome extension ID, which must then be updated in
  `BrowserIntegrationService.chromeExtensionID` or native messaging will be refused. Derive
  it as the first 16 bytes of the SHA-256 of the DER public key, hex digits mapped `0-f` →
  `a-p`.
- **Debugging the hand-off** — the service worker's console (`chrome://extensions` →
  *service worker*) logs why a send failed. It deliberately never logs the message itself,
  which can hold a session cookie.

---

## Next

- [Getting started](getting-started.md)
- [FAQ](faq.md)
- [Troubleshooting](troubleshooting.md)
