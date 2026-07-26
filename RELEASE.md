# Releasing Goel°

CI (`.github/workflows/ci.yml`) builds, tests and runs the deployment-target and
Info.plist gates on every push and pull request, but it does **not** cut releases —
signing needs a certificate that cannot live on a hosted runner. So this file is
still the release pipeline. Follow it top to bottom, in order, ticking boxes as
you go. It is written to be followed at 1am by someone who is tired and has
forgotten everything, so nothing is left implicit.

Every step is copy-pasteable from the repo root. The app bundle is
`dist/Goel°.app` — the `°` is part of the name, so **always keep the quotes**.

---

## 0. One-time setup (skip once done)

These four things cannot be automated and must exist before your first signed
release. If any is missing, stop and do it now — none of it can be faked.

| # | What | How |
|---|------|-----|
| 0.1 | Apple Developer Program membership (US$99/yr) | <https://developer.apple.com/programs/enroll/> — takes hours to days to approve |
| 0.2 | **Developer ID Application** certificate in your login keychain | Xcode → Settings → Accounts → Manage Certificates → **+** → *Developer ID Application*. Verify with `security find-identity -v -p codesigning` |
| 0.3 | An app-specific password + a stored `notarytool` profile | see below |
| 0.4 | A Sparkle EdDSA key pair | see below |

**0.3 — store the notarytool credentials once:**

```bash
# Create an app-specific password at https://account.apple.com → Sign-In and Security
# → App-Specific Passwords. Then store it in the keychain under a profile name:
xcrun notarytool store-credentials "goel-notary" \
  --apple-id "you@example.com" \
  --team-id  "YOURTEAMID" \
  --password "abcd-efgh-ijkl-mnop"      # the app-specific password, NOT your Apple ID password

# Sanity check (should print an empty or historical submission list, not an auth error):
xcrun notarytool history --keychain-profile "goel-notary"
```

`goel-notary` is the string you will pass as `NOTARY_PROFILE`.

**0.4 — generate the Sparkle signing key ONCE, ever:**

```bash
swift build -c release                       # materialises the Sparkle artifact bundle
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It prints a **base64 public key** and stores the **private key in your login
keychain** (item name *"Private key for signing Sparkle updates"*).

* The public key is what you pass as `SPARKLE_ED_KEY` — it is safe to commit and
  ships inside every build's Info.plist.
* The private key never leaves your Mac. **Back it up now**
  (`generate_keys -x sparkle_private_key.txt` writes it to a file — put that file
  in your password manager and delete it from disk). If you lose it, every
  existing installation is permanently cut off from auto-updates and users must
  re-download by hand. There is no recovery.

---

## 1. Pre-flight

- [ ] `git status` is clean, you are on `main`, and `git pull` is done.
- [ ] Decide the new version, e.g. `1.1.0`. It must be **higher** than the last
      tag (`git tag --sort=-v:refname | head -1`) and must never be reused.
- [ ] Skim the diff since the last tag for anything that violates the product
      guarantees: **no telemetry, no analytics, no crash uploads, no licence-key
      check, no trial clock, no feature gating.**
      `git diff v<PREVIOUS>..HEAD -- Sources/ | grep -inE 'analytics|telemetry|beacon|track|licen[cs]e[-_ ]?key|trial'`
      Anything that hits needs a human read before you continue.
- [ ] `LICENSE` (PolyForm Noncommercial 1.0.0) and `THIRD-PARTY-NOTICES.md`
      exist at the repo root — `build_app.sh` copies both into the bundle and
      the BSD/Apache notices are a redistribution obligation.

## 2. Version bump

The version comes from the **git tag** (`build_app.sh` reads
`git describe --tags --exact-match`), so there is nothing to hand-edit for the
version itself. Update the human-facing bits only:

- [ ] `README.md` — anything that names the old version.
- [ ] Write the release notes now, while the changes are fresh. You need them
      twice: in the appcast item and in the GitHub release.
- [ ] Commit any doc changes: `git commit -am "docs: notes for v1.1.0"`

> The literals in `build_app.sh`'s Info.plist heredoc are only the fallback for
> untagged working-copy builds. `CFBundleVersion` is set from
> `git rev-list --count HEAD` so it always increases — Sparkle uses it to decide
> what "newer" means. Override either with `GOEL_VERSION` / `GOEL_BUILD` if you
> must, but you should not have to.

## 3. Build and test

```bash
swift build -c release
swift test          # the whole suite must pass — 418 tests, ~13s
```

- [ ] Release build succeeds with no warnings you have not already seen.
- [ ] **The entire suite passes** — 418 tests at the time of writing. The count grows with
      the project; the acceptable failure count does not. A single failure stops the
      release: no exceptions, no "it's flaky", no `--filter` to skip it.

## 4. Tag now (before packaging)

The tag has to exist *before* `build_app.sh` runs, because the script reads the
version from it. Tag locally; do not push yet — if step 5 or 6 fails you want to
be able to delete the tag without having published it.

```bash
git tag -a v1.1.0 -m "Goel° 1.1.0"
git describe --tags --exact-match         # must print exactly: v1.1.0
```

## 5. Package the signed, notarized app

Set the env vars in the same shell, then run the build script.

```bash
export GOEL_RELEASE=1                       # required — see below
export CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
export NOTARY_PROFILE="goel-notary"
export BUNDLE_YTDLP=1                       # 1 = bundle yt-dlp (~35 MB, recommended)
export SPARKLE_FEED_URL="https://github.com/vinitkumargoel/goel/releases/latest/download/appcast.xml"
export SPARKLE_ED_KEY="<base64 public key printed by generate_keys>"

Scripts/build_app.sh
```

**`GOEL_RELEASE=1` is not optional.** Without it the script produces a *local*
build — signed with whatever identity is handy so macOS keeps its privacy
grants, and deliberately **not** packaged into `dist/…​.zip`. That is the point:
an Apple Development signature is perfectly valid for signing and is rejected by
Gatekeeper on every machine that is not yours, so a build that cannot pass must
not be able to produce a file that looks like a release. With `GOEL_RELEASE=1`
the script demands a Developer ID Application certificate, refuses to fall back
to anything else, and gates the archive on `spctl` reporting
`source=Notarized Developer ID` plus a valid stapled ticket.

What the script does with each variable:

| Env var | Effect |
|---|---|
| `GOEL_RELEASE` | `1` demands a Developer ID Application identity, a configured updater and a clean Gatekeeper assessment, and is the only way a distributable archive is emitted. Unset/`0` → local build, no archive. |
| `CODESIGN_IDENTITY` | Signs inside-out with hardened runtime + `Scripts/Goel.entitlements`. Under `GOEL_RELEASE=1` it must start with `Developer ID Application: `, spelled exactly as `security find-identity -v -p codesigning` prints it; leave it unset and the script picks the single Developer ID identity, or refuses if there are none or several. Outside a release, unset → auto-picks the first identity in your keychain (dev convenience) and `-` → ad-hoc. |
| `NOTARY_PROFILE` | Submits to Apple's notary service, waits, and staples the ticket to the `.app`. Only runs when `CODESIGN_IDENTITY` is set. |
| `GOEL_NO_UPDATER` | `1` acknowledges shipping a release with no Sparkle feed. Without it, `GOEL_RELEASE=1` refuses to build when `SPARKLE_FEED_URL`/`SPARKLE_ED_KEY` are unset. |
| `GOEL_LOCAL_DEV` | `1` downgrades the deployment-target gates to warnings for a throwaway build. Mutually exclusive with `GOEL_RELEASE=1`, never produces an archive, and — because a stapled ticket is what makes a bundle look shippable to `make_dmg.sh` — refuses to notarize or staple a bundle whose gate it waived. |
| `BUNDLE_YTDLP` | `1` (default) bundles a frozen yt-dlp; `0` ships without it and the "Resolve with yt-dlp" button stays hidden. |
| `SPARKLE_FEED_URL` | Written to `Info.plist` as `SUFeedURL`. Must be `https://`. |
| `SPARKLE_ED_KEY` | Written to `Info.plist` as `SUPublicEDKey`. |
| `GOEL_VERSION` / `GOEL_BUILD` | Override the tag-derived `CFBundleShortVersionString` / `CFBundleVersion`. |
| `GOEL_ARCH` | `x86_64` (with `GOEL_BREW_PREFIX=/usr/local`) to cross-build an Intel app. |

`SPARKLE_FEED_URL` and `SPARKLE_ED_KEY` are all-or-nothing: supply both or
neither. The script refuses to build with only one, and
`SparkleUpdaterService` refuses to start the updater on a half-configured
bundle — that combination would mean downloading updates it cannot verify.

Expected tail of the output: `signed & verified.`, then
`notarized and stapled.`, then `==> Done: dist/Goel°.app`.

**If notarization is rejected**, get the reason — the submission ID is in the
`notarytool submit` output:

```bash
xcrun notarytool log <SUBMISSION-ID> --keychain-profile "goel-notary"
```

## 6. Verify the ticket is really stapled

Do not skip this. A build that signs fine but fails here will show users the
"damaged / cannot be opened" dialog, and you will find out from a bug report.

```bash
# 6a. The stapled notarization ticket is present and valid:
xcrun stapler validate -v "dist/Goel°.app"
#     → "The validate action worked!"

# 6b. Gatekeeper accepts it as it would on a clean Mac:
spctl -a -vvv -t exec "dist/Goel°.app"
#     → dist/Goel°.app: accepted
#       source=Notarized Developer ID
#       origin=Developer ID Application: Your Name (YOURTEAMID)

# 6c. The signature is intact all the way down (nested helpers, dylibs, appex):
codesign --verify --strict --deep --verbose=4 "dist/Goel°.app"
#     → "valid on disk" + "satisfies its Designated Requirement"

# 6d. The hardened runtime and the intended entitlements are actually on it:
codesign -d --verbose=4 --entitlements - "dist/Goel°.app" 2>&1 | grep -E 'flags|disable-library-validation'
#     → flags=0x10000(runtime)  and the disable-library-validation key

# 6e. The version really is the one you tagged:
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "dist/Goel°.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL'                 "dist/Goel°.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey'             "dist/Goel°.app/Contents/Info.plist"
```

`source=Notarized Developer ID` in 6b is the one line that matters. If it says
`source=Unnotarized Developer ID`, the staple did not happen — re-run step 5.

- [ ] Smoke test by hand: copy the app to `/Applications`, launch it, add one
      HTTP download and one torrent, quit. Anything that only breaks in a signed
      hardened-runtime build (dylib loading, yt-dlp spawning) breaks here and
      nowhere else.

## 7. Build the DMG

```bash
Scripts/make_dmg.sh          # NOTARY_PROFILE still exported → the DMG is notarized+stapled too
xcrun stapler validate -v "dist/Goel-Downloader-1.1.0-macos-arm64.dmg"
spctl -a -vvv -t install     "dist/Goel-Downloader-1.1.0-macos-arm64.dmg"
```

Note `-t install` (not `-t exec`) for a disk image.

`make_dmg.sh` re-runs the deployment-target gate and the Gatekeeper assessment on
the app it was handed — it is a release path in its own right and cannot assume
`build_app.sh` ran in the same invocation. It also builds the image in a scratch
directory and moves it into `dist/` only after signing, notarization, stapling and
the final assessment have all passed, so a failure leaves nothing behind that
looks like a release.

You now have two artifacts in `dist/`:

* `Goel-Downloader-1.1.0-macos-arm64.dmg` — the human download, linked from the README.
* `Goel-Downloader-1.1.0-macos-arm64.zip` — created by `build_app.sh` **after**
  stapling, so it contains the stapled app. **This is the file Sparkle updates
  from.** Do not hand-make a zip; `ditto -c -k --keepParent` preserves the
  bundle's symlinks and extended attributes and `zip` does not.

## 8. Sign the update for Sparkle

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update \
  "dist/Goel-Downloader-1.1.0-macos-arm64.zip"
```

It prints the attributes to paste into the appcast, e.g.:

```
sparkle:edSignature="Xf3k…==" length="19283746"
```

This reads the private key from your keychain — macOS may prompt for your login
password. If it errors with "no private key found", you are on a machine that
never ran `generate_keys`; the release must be cut on the machine that holds the
key.

## 9. Append the appcast item

Edit `appcast.xml` (kept wherever `SPARKLE_FEED_URL` points; if this is your
first release, create it from the skeleton below). **Append** the new `<item>`
above the previous one — never delete old items, Sparkle uses them to serve
users on older versions.

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Goel° Updates</title>
    <item>
      <title>1.1.0</title>
      <pubDate>Fri, 25 Jul 2026 12:00:00 +0000</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <ul><li>What changed, in plain language.</li></ul>
      ]]></description>
      <enclosure
        url="https://github.com/vinitkumargoel/goel/releases/download/v1.1.0/Goel-Downloader-1.1.0-macos-arm64.zip"
        sparkle:version="57"
        sparkle:shortVersionString="1.1.0"
        sparkle:edSignature="PASTE_FROM_STEP_8"
        length="PASTE_FROM_STEP_8"
        type="application/octet-stream" />
    </item>
    <!-- older items below, untouched -->
  </channel>
</rss>
```

- [ ] `sparkle:version` matches `CFBundleVersion` from step 6e **exactly**.
      Sparkle compares this field, not `shortVersionString`. Get it wrong and
      either nobody is offered the update or everybody is offered it forever.
- [ ] `url` is the URL the file will have *after* step 11 — the GitHub release
      asset URL. Upload first, then publish the appcast (step 12), so the feed
      never points at a 404.

## 10. Push the tag

```bash
git push origin main
git push origin v1.1.0
```

## 11. GitHub release

```bash
gh release create v1.1.0 \
  --title "Goel° 1.1.0" \
  --notes-file /path/to/notes.md \
  "dist/Goel-Downloader-1.1.0-macos-arm64.dmg" \
  "dist/Goel-Downloader-1.1.0-macos-arm64.zip"
```

- [ ] Download the DMG from the release page **on a different Mac** (or at least
      in a fresh folder after `xattr -w com.apple.quarantine ...`), open it, and
      drag-install. It must open with no Gatekeeper warning at all. This is the
      only test that exercises the quarantine path your users actually hit.

## 12. Publish the appcast

Only now, once the asset URLs resolve, publish `appcast.xml` to whatever
`SPARKLE_FEED_URL` points at, and confirm:

```bash
curl -sSfI "$SPARKLE_FEED_URL" | head -1        # → HTTP/2 200
curl -sSf  "$SPARKLE_FEED_URL" | head -40       # → your new <item> at the top
```

- [ ] On a machine running the *previous* version, `Goel° → Check for Updates…`
      offers 1.1.0 and installs it. If Sparkle reports a signature failure, the
      zip you signed in step 8 is not byte-identical to the one you uploaded in
      step 11 — re-sign the uploaded file and fix the appcast.

## 13. Done

- [ ] Update the README download link to the new version.
- [ ] `rm -rf dist` when you no longer need the artifacts locally.

---

## Rollback

Auto-updates are the thing that can hurt people, so **the appcast is the kill
switch and it is the first thing you touch.**

1. **Stop the rollout.** Remove the bad `<item>` from `appcast.xml` and publish
   immediately. Sparkle stops offering the release within one feed fetch.
   Everything below can wait; this cannot.
2. **De-list the download.** `gh release edit v1.1.0 --prerelease` hides it from
   "Latest" while keeping the URLs alive (so anyone mid-download is not left
   with a truncated file), or `gh release delete v1.1.0` if it must go entirely.
3. **Do not un-tag a pushed tag** unless the release was up for minutes and you
   are certain nobody fetched it. Deleting a published tag breaks every clone
   that already has it.
4. **Roll forward, never backward.** Never re-issue a fixed build under the same
   version number: `CFBundleVersion` must increase, and Sparkle will not offer a
   version that is not newer than what the user already has. Fix the bug, cut
   `v1.1.1`, and run this checklist again from step 1.
5. **Users already on the bad version** can only be rescued by a newer release.
   There is no remote disable, no kill switch inside the app, and there is not
   going to be one — the app has no phone-home and it stays that way.
6. If the *notarization* was the problem (Apple revoked or the ticket is bad),
   the app on disk keeps working; only fresh downloads are affected. Fix the
   signing and re-notarize, no version bump needed if the binary is unchanged —
   but re-verify with step 6.

---

## Quick reference

```bash
export GOEL_RELEASE=1
export CODESIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
export NOTARY_PROFILE="goel-notary"
export BUNDLE_YTDLP=1
export SPARKLE_FEED_URL="https://…/appcast.xml"
export SPARKLE_ED_KEY="…"

swift build -c release && swift test          # all of it must pass
git tag -a v1.1.0 -m "Goel° 1.1.0"
Scripts/build_app.sh
xcrun stapler validate -v "dist/Goel°.app" && spctl -a -vvv -t exec "dist/Goel°.app"
Scripts/make_dmg.sh
.build/artifacts/sparkle/Sparkle/bin/sign_update "dist/Goel-Downloader-1.1.0-macos-arm64.zip"
# → paste into appcast.xml
git push origin main && git push origin v1.1.0
# Name the two files explicitly — never glob dist/. It is not pruned between
# releases, so a glob uploads every artifact still lying there, including ones
# built before a gate existed, under a version nobody is releasing today.
gh release create v1.1.0 --title "Goel° 1.1.0" --notes-file notes.md \
  "dist/Goel-Downloader-1.1.0-macos-arm64.dmg" \
  "dist/Goel-Downloader-1.1.0-macos-arm64.zip"
# → publish appcast.xml last
```
