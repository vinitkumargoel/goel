# Changelog

All notable changes to Goel° are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.2] — 2026-07-25

First release under the **PolyForm Noncommercial 1.0.0** licence. If you use Goel° at work,
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

[Unreleased]: https://github.com/vinitkumargoel/goel/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/vinitkumargoel/goel/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/vinitkumargoel/goel/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vinitkumargoel/goel/releases/tag/v1.0.0
