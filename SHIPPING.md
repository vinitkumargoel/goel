# Shipping Goel° — Feasibility & Distribution Study

> **Question this answers:** "If I put the `.dmg` on GitHub (or a website) and people download
> it onto *any* Mac — an empty one, a fresh one, an old one — will it break? What do I need to do
> so it doesn't?"

**TL;DR** — The app is already **self-contained** (every third-party library is packed inside it,
no Homebrew needed on the user's Mac). The thing that *will* break a GitHub download is **not**
dependencies — it's **macOS Gatekeeper**, because anything downloaded from the internet is
quarantined and an *ad-hoc-signed* app gets refused. To ship cleanly you need **Developer ID
signing + notarization** (one-time Apple Developer Program, $99/yr). Everything else is already
handled or is a documentation note.

---

## 1. The verdict matrix — will it run?

| Scenario | Runs today (ad-hoc, as-is)? | Runs after Dev-ID + notarize? |
|---|---|---|
| **You build it, run locally** (no quarantine) | ✅ Yes | ✅ Yes |
| **You `.zip`/`.dmg` it, AirDrop/USB to another Mac** | ⚠️ Runs, but the copy may be quarantined → 1 warning | ✅ Yes, no warning |
| **User downloads `.dmg` from GitHub — Apple Silicon** | ❌ Blocked: *"Apple cannot check it for malicious software"* (bypassable) | ✅ **Just opens** |
| **User downloads `.dmg` from GitHub — Intel Mac** | ❌ Won't run **at all** (arm64-only binary) | ❌ Still won't run (arm64-only) |
| **Empty/fresh Mac, no Homebrew, no dev tools (Apple Silicon, macOS 14+)** | ❌ Gatekeeper only (bypassable) — libraries are fine | ✅ **Just opens** |
| **Mac on macOS 13 or older** | ❌ Won't launch (built for macOS 14+) | ❌ Won't launch (raise/lower the floor to change this) |

**Two, and only two, things break a download:** (1) **Gatekeeper** (fix: notarize), and
(2) **Intel Macs** (fix: universal build, or just declare Apple-Silicon-only). Dependencies do **not**
break it — that problem is already solved.

---

## 2. Self-containment — already done (proof)

`Scripts/bundle_dylibs.sh` copies the full native-library closure **into** the app and rewrites it
to load them from inside itself. A user needs **no Homebrew, no libtorrent, no OpenSSL, nothing**.

```
Goel°.app/Contents/Frameworks/
├── libtorrent-rasterbar.2.0.dylib   (4.0 MB)  ← BitTorrent
├── libcrypto.3.dylib                (4.3 MB)  ← OpenSSL (crypto)
├── libssl.3.dylib                   (814 KB)  ← OpenSSL (TLS)
├── libssh2.1.dylib                  (243 KB)  ← SFTP
└── Sparkle.framework                          ← auto-update
```

- `libcurl` (FTP/FTPS) is **Apple's own** `/usr/lib/libcurl.4.dylib` — always present, never bundled.
- `boost` is **statically linked inside** libtorrent — not a separate file.
- The Swift runtime is part of macOS 12.3+ — intentionally not bundled.
- Verified: **zero `/opt/homebrew` references** remain anywhere in the shipped app.

> **Homebrew is a *build-machine* tool only.** You run `brew install` once on *your* Mac to compile.
> The user never sees it. Build-time dependency ≠ runtime dependency.

---

## 3. THE make-or-break issue for GitHub distribution: Gatekeeper & notarization

This is the single most important section for your plan.

### What happens on a download

macOS tags every downloaded file with a **quarantine** attribute (`com.apple.quarantine`).
On first launch of a quarantined app, **Gatekeeper** checks *who signed it*:

| Signature the app carries | Result on a downloaded copy |
|---|---|
| **Ad-hoc** (what you ship *today* — `codesign -s -`, no Team ID) | ❌ *"Goel° can't be opened because Apple cannot check it for malicious software."* Blocked by default. |
| **Developer ID, NOT notarized** | ❌ Same block (as of macOS 10.15+ notarization is required). |
| **Developer ID + notarized + stapled** | ✅ Opens with no warning (or a one-time "downloaded from the internet — Open?" on first launch). |

**So as-is, every GitHub downloader hits a scary wall.** They *can* get past it (right-click → Open,
or System Settings → Privacy & Security → "Open Anyway"), but for a public release that reads as
"broken/malware" and kills trust.

### The fix: Developer ID + notarization (the real ship-ready path)

1. **Join the Apple Developer Program** — $99/yr. This is the only hard prerequisite; there is no
   way to notarize without it.
2. **Create a "Developer ID Application" certificate** (Xcode → Settings → Accounts, or the
   developer portal).
3. **Sign with hardened runtime + entitlements**, then **notarize + staple**. Your build script
   **already has these hooks** — they're just gated behind env vars:
   ```bash
   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="your-notarytool-keychain-profile" \
   Scripts/build_app.sh
   ```
   `build_app.sh` will then sign every dylib/framework/helper with hardened runtime, sign the app,
   submit to Apple's notary service, wait, and staple the ticket.

### What notarization requires that we must add

- **A hardened runtime entitlements file.** Because the app loads **bundled (non-Apple) dylibs**
  and (once bundled) runs **yt-dlp** as a child process, notarization needs specific entitlements:
  - `com.apple.security.cs.disable-library-validation` — lets the hardened app load our own
    signed-but-not-by-Apple dylibs *and* run the PyInstaller-based yt-dlp (which loads its own
    unsigned `.so` files at runtime). **Without this, yt-dlp and possibly the vendored dylibs fail
    to load under hardened runtime.**
  - `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` — Python (inside yt-dlp)
    can need these. Add if notarization/yt-dlp complains.
  - Network client & server are allowed by default outside the App Sandbox (we are not sandboxed).
  - *(This entitlements file is added as part of the yt-dlp bundling work — see §6.)*
- **All nested executables signed** — the vendored dylibs, Sparkle's helpers (`Updater.app`,
  `Autoupdate`, XPC services), the Safari `.appex`, and **yt-dlp** must each be signed with the
  same Developer ID and hardened runtime, **inside-out**, before the outer app is sealed.

### If you decide NOT to pay for the Developer Program (interim only)

Ship it, but **document the one-time bypass** in your README and release notes:

```bash
# After downloading, if macOS says the app "can't be opened":
xattr -dr com.apple.quarantine "/Applications/Goel°.app"
```
or right-click the app → **Open** → **Open**. This is acceptable for a beta / for technical users,
**not** for a polished public release. **Recommendation: budget the $99 and notarize.** It is the
difference between "looks like malware" and "double-click, done."

---

## 4. CPU architecture — arm64-only (Intel Macs won't run it)

The executable **and** every vendored dylib are **arm64 only** (they come from Apple-Silicon
Homebrew). Consequences:

- ✅ Runs on **all Apple Silicon Macs** — every Mac since **Nov 2020** (M1 and later). This is the
  large and growing majority.
- ❌ Does **not** run on **Intel Macs** at all — not even under Rosetta (Rosetta translates x86→arm,
  not the reverse). An Intel user gets *"application can't be opened"*.

**Options:**

| Option | Effort | Who it serves |
|---|---|---|
| **Ship Apple-Silicon-only** (label it clearly) | None | Every Mac 2020+ — recommended |
| **Universal build (arm64 + x86_64)** | High | + Intel Macs (a shrinking base) |

A universal build means obtaining/compiling **x86_64 copies of libtorrent, OpenSSL, libssh2** (a
second Homebrew under Rosetta, or cross-compiling the native libs) and `lipo`-joining everything.
That is real, ongoing work for a user base that shrinks every year.

**Recommendation:** ship **Apple-Silicon-only for v1**, and say so on the download page
("Requires an Apple Silicon Mac, macOS 14 or later"). Revisit universal only if real Intel demand
shows up. The `LSMinimumSystemVersion`/download page must state this or Intel users file "broken" bugs.

---

## 5. macOS version floor — 14.0 (Sonoma)

`Info.plist` sets `LSMinimumSystemVersion = 14.0`, and the code uses modern APIs
(`SMAppService` login items = macOS 13+, SwiftUI features, Safari Web Extension = 12+). A Mac on
**macOS 13 or earlier will refuse to launch it**.

- macOS 14 (Sonoma, Sept 2023) covers essentially all Apple Silicon Macs that keep up with updates.
- Lowering the floor (e.g. to 13) is possible but needs testing of the version-gated APIs; not worth
  it for v1.
- **Action:** state **"macOS 14 (Sonoma) or later"** on the download page.

---

## 6. yt-dlp bundling — feasibility & the trade-off you should weigh

You asked to bundle yt-dlp *inside* the app so video-site downloads work on an empty Mac. This is
**doable**, and I'll implement it, but here is the honest trade-off so the decision is informed:

**The plan (self-contained, works on an empty Mac):**
- Bundle the official **`yt-dlp_macos`** standalone binary. It is **PyInstaller-frozen** — it carries
  its *own* Python inside, so it needs **no system Python** (macOS ships none since 12.3). ✅ Empty-Mac safe.
- The resolver already uses `-f b` (best **single muxed** stream), so it needs **no `ffmpeg`** to
  merge audio+video. ✅ No second binary required.
- `YtDlpResolver.swift` is changed to look **inside the bundle first**, then fall back to a
  user-installed copy.

**The costs (why it's a real trade-off):**
- **Size:** `yt-dlp_macos` is **~35 MB**. Your bundle goes from **17 MB → ~52 MB** — you spent effort
  shrinking it; this undoes that. The `.dmg` download roughly doubles.
- **Notarization friction:** PyInstaller binaries extract and `dlopen` **unsigned** `.so` files at
  runtime → under hardened runtime this **requires** `com.apple.security.cs.disable-library-validation`
  (and possibly `allow-jit`). Handled by the entitlements file, but it's the reason yt-dlp is the
  fussiest thing to notarize.
- **Staleness:** a bundled yt-dlp is frozen at build time. Video sites change; yt-dlp ships fixes
  weekly. A copy bundled today may fail on some sites in 3 months — the user can't `pip upgrade` it.
  (Your own app-update cadence becomes yt-dlp's update cadence — which you said is fine.)
- **Licensing:** yt-dlp is **Unlicense** (public domain) — perfectly fine to bundle; added to
  `THIRD-PARTY-NOTICES`.

**Three ways to do it (I'll implement whichever you keep):**

| Approach | Bundle size | Empty-Mac | Freshness | Notarization |
|---|---|---|---|---|
| **A. Bundle `yt-dlp_macos`** (what you asked for) | +35 MB | ✅ works offline | frozen at build | needs entitlement |
| **B. Download on first use** into Application Support | +0 MB | needs network *once* | always latest | cleanest |
| **C. Stay optional** (today) — user installs via brew/pip | +0 MB | ❌ button hidden | user-managed | none |

**My recommendation: A is fine given you want it in-box** — I'll implement A with the entitlement,
and structure the resolver so switching to B later is trivial (bundle-first → app-support → system).
If the +35 MB bothers you, **B** gives the same "just works" feel for most users at zero bundle cost.

---

## 7. Sparkle — how updates actually work, and how to make them live

Sparkle is **already bundled** (`Contents/Frameworks/Sparkle.framework`) exactly like the native
libs — same mechanism, loaded via `@rpath` from inside the app. So "can't we do the same for
Sparkle?" — **it's already done.** What's missing is the *configuration* that turns it on.

### Two update paths exist in the code — pick one

**Path 1 — Full Sparkle (silent, in-app "Update & Relaunch"):** the good UX.
- You host an **appcast.xml** feed (a list of versions + signed `.zip`/`.dmg` URLs). **GitHub is
  perfect for this** — host `appcast.xml` on **GitHub Pages** (or in the repo) and point the release
  archive URLs at your **GitHub Releases** assets.
- Sparkle activates only when the app's `Info.plist` carries `SUFeedURL` + `SUPublicEDKey`. The build
  script wires these from env vars:
  ```bash
  SPARKLE_FEED_URL="https://vinitkumargoel.github.io/goel-downloader/appcast.xml" \
  SPARKLE_ED_KEY="<public key from Sparkle's generate_keys>" \
  Scripts/build_app.sh
  ```
- Each release: run Sparkle's `generate_appcast` over your release archives (it signs them with your
  **EdDSA** key), commit the updated `appcast.xml`. Users get "A new version is available → Install".

**Path 2 — Built-in lightweight checker (already coded, zero hosting):** the simple fallback.
- `UpdateChecker.swift` hits a **GitHub Releases API feed**, compares versions, and if newer, opens
  the release page in the browser for a manual download.
- Turn it on by defaulting `updateFeedURL` to your repo:
  `https://api.github.com/repos/vinitkumargoel/goel-downloader/releases/latest`
- No appcast, no signing key, no hosting — but the user downloads + drags manually each time.

### Recommendation for a GitHub-distributed app

**Start with Path 2** (it's already written; flip the default feed URL + enable auto-check → you're
done, updates "work" immediately). **Graduate to Path 1** when you want the polished silent updater —
GitHub Pages hosts the appcast for free. Either way, **Sparkle staying bundled costs you nothing**
except a bit more signing work (its helper apps must be signed inside-out — the build script already
does this).

---

## 8. Third-party library update strategy (your decision — and it's the right one)

You said: *"I don't want a separate third-party updater — when I publish a new app version it carries
the new library versions."* **That is exactly the standard, correct approach for a bundled app.**

- Native libs (libtorrent/OpenSSL/libssh2) are **frozen at build time** and travel inside each release.
- To ship newer libs: `brew upgrade` on your build machine → rebuild → cut a new release. The whole
  app updates atomically; there is no partial/independent library update to go wrong.
- **Security note:** the one library worth watching is **OpenSSL** (it gets CVEs). When a notable
  OpenSSL advisory lands, `brew upgrade openssl@3` and cut a patch release. That's the entire
  maintenance burden — no runtime machinery needed.

---

## 9. Empty-Mac scenario walk-through (the "unlimited scenarios" worry)

A brand-new Mac out of the box (Apple Silicon, macOS 14+), no Homebrew, no dev tools, downloads your
`.dmg` from GitHub. Step by step:

1. **Download** → the `.dmg` is quarantined. *(Gatekeeper will check the signature — see §3.)*
2. **Open the `.dmg`, drag Goel° to Applications** → the app inherits quarantine.
3. **Double-click** →
   - *Today (ad-hoc):* ❌ blocked, needs the right-click-Open bypass.
   - *After notarization:* ✅ opens, maybe one "downloaded from the internet — Open?" click.
4. **App launches** → loads libtorrent/OpenSSL/libssh2 **from inside itself** ✅ (no Homebrew needed),
   SQLite/libcurl/Swift runtime **from macOS** ✅ (always present).
5. **Every feature works** — HTTP/segmented, FTP, SFTP, BitTorrent, HLS. ✅
6. **Video-site button** → works if yt-dlp is bundled (§6); otherwise hidden until the user installs it.

**Conclusion:** on any Apple-Silicon Mac (macOS 14+), the *only* thing between the user and a working
app is the **Gatekeeper prompt** — which notarization removes. Nothing about the bundled libraries
breaks. On an **Intel** Mac it won't run regardless (§4). On **macOS ≤13** it won't run (§5).

---

## 10. Ship-ready action checklist

**Must-do for a clean public GitHub release:**
- [ ] **Join Apple Developer Program** ($99/yr) → get a *Developer ID Application* cert.
- [ ] Add the **hardened-runtime entitlements** file (done as part of yt-dlp bundling, §6).
- [ ] Build with `CODESIGN_IDENTITY` + `NOTARY_PROFILE` set → **notarize + staple** (hooks exist).
- [ ] Ship a **`.dmg`** (drag-to-Applications) — script added (`Scripts/make_dmg.sh`).
- [ ] On the download page state: **"Apple Silicon Mac, macOS 14 (Sonoma) or later."**
- [ ] Add **LICENSE + THIRD-PARTY-NOTICES** (bundling their code obliges including their licenses).

**Recommended:**
- [ ] Turn on updates — default `updateFeedURL` to your GitHub Releases API (Path 2), or host an
      **appcast on GitHub Pages** for full Sparkle (Path 1).
- [ ] Decide yt-dlp: **bundle (+35 MB)** or **download-on-first-use (0 MB)** — §6.

**Optional / later:**
- [ ] Universal (arm64+x86_64) build if Intel demand appears.
- [ ] Lower the macOS floor below 14 if you need older Macs.

**Already done — no action:**
- [x] Native third-party libraries bundled inside the app (no Homebrew for users).
- [x] Sparkle bundled inside the app.
- [x] `libcurl`/SQLite/Swift runtime resolved from macOS.
- [x] yt-dlp optional & graceful when absent (becomes bundled per §6).
</content>
</invoke>
