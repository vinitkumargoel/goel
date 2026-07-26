# Software Bill of Materials — Goel° Download Manager

**Document version:** 1.0
**Last updated:** 2026-07-25
**Primary component:** Goel° Download Manager
**Supplier:** Vinit Kumar Goel
**Licence (this product):** PolyForm Noncommercial 1.0.0 — commercial licences available
**Contact:** licensing@vinitk.dev

This is a human-readable SBOM in SPDX field order, derived from
[`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md), [`Package.swift`](../../Package.swift)
and [`Package.resolved`](../../Package.resolved). A machine-readable SPDX 2.3 JSON or
CycloneDX document for a specific release is provided on request as part of a Business or
Enterprise licence.

---

## 1. Summary for reviewers

| Question | Answer |
|---|---|
| Any copyleft (GPL/LGPL/AGPL) in the shipped binary? | **No.** |
| Licence families present | BSD-3-Clause, BSL-1.0, Apache-2.0, MIT, Unlicense |
| Any component requiring source disclosure by you? | **No.** |
| Any component with a commercial-use restriction? | **No** (the restriction is on Goel° itself, not its dependencies) |
| Attribution obligation | Yes — redistribute `THIRD-PARTY-NOTICES.md` with the app |
| Known-vulnerable pinned versions at time of writing | None known |
| Direct Swift package dependencies | 3 (GRDB.swift, Sparkle, plus swift-crypto/swift-nio on Linux) |
| Bundled native libraries | 4 (libtorrent-rasterbar, Boost, OpenSSL, libssh2) |

---

## 2. Package components

Fields follow SPDX package properties: `PackageName`, `PackageVersion`,
`PackageLicenseDeclared`, `PackageSupplier`, `PackageDownloadLocation`, `FilesAnalyzed`,
`PackageComment`.

### 2.1 Primary package

```
PackageName:            GoelDownloader
PackageVersion:         see release tag
PackageLicenseDeclared: LicenseRef-PolyForm-Noncommercial-1.0.0
PackageSupplier:        Person: Vinit Kumar Goel
PackageDownloadLocation: https://github.com/vinitkumargoel/goel
PrimaryPackagePurpose:  APPLICATION
PackageComment:         macOS 14+ arm64 SwiftUI application (GoelApp) and headless
                        Linux daemon (GoelDaemon) over a shared engine (GoelCore).
                        Swift 6.3 toolchain, swift-tools-version 5.10.
```

Internal targets, no separate licensing — all covered by the primary licence:
`GoelCore`, `GoelApp`, `GoelDaemon`, `TorrentBridge`, `CurlBridge`, `SSHBridge`,
`CryptoBridge`.

### 2.2 Swift package dependencies

```
PackageName:            GRDB.swift
PackageVersion:         6.29.3  (resolved; declared "from: 6.29.0")
PackageLicenseDeclared: MIT
PackageSupplier:        Person: Gwendal Roué
PackageDownloadLocation: https://github.com/groue/GRDB.swift.git
PackageChecksum:        SHA1: 2cf6c756e1e5ef6901ebae16576a7e4e4b834622  (git revision)
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         SQLite persistence for the queue and history.
                        Statically linked into the executable.
                        Platforms: macOS + Linux.
```

```
PackageName:            Sparkle
PackageVersion:         2.9.3  (resolved; declared "from: 2.6.0")
PackageLicenseDeclared: MIT
PackageSupplier:        Organization: Sparkle Project
PackageDownloadLocation: https://github.com/sparkle-project/Sparkle
PackageChecksum:        SHA1: d46d456107feacc80711b21847b82b07bd9fb46e  (git revision)
FilesAnalyzed:          false
PrimaryPackagePurpose:  FRAMEWORK
PackageComment:         macOS update framework. Ships at
                        Goel°.app/Contents/Frameworks/Sparkle.framework.
                        macOS only — not present in Linux builds.
                        Update checking is user-disableable (Settings → Updates).
                        Sparkle bundles further BSD/permissive components; see the
                        Sparkle project for its own complete list.
```

```
PackageName:            swift-crypto
PackageVersion:         >= 3.0.0
PackageLicenseDeclared: Apache-2.0
PackageSupplier:        Organization: Apple Inc.
PackageDownloadLocation: https://github.com/apple/swift-crypto.git
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         LINUX BUILDS ONLY. Stands in for CryptoKit/CommonCrypto.
                        Not present in macOS builds.
```

```
PackageName:            swift-nio
PackageVersion:         >= 2.65.0
PackageLicenseDeclared: Apache-2.0
PackageSupplier:        Organization: Apple Inc.
PackageDownloadLocation: https://github.com/apple/swift-nio.git
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         LINUX BUILDS ONLY. Products used: NIOCore, NIOPosix, NIOHTTP1.
                        Stands in for Network.framework in the remote-control server.
                        Not present in macOS builds.
```

### 2.3 Bundled native libraries (macOS)

These ship inside `Goel°.app/Contents/Frameworks/`. On Linux the equivalents come from the
distribution's own packages and are **not** redistributed by us.

```
PackageName:            libtorrent-rasterbar
PackageVersion:         2.0.x
PackageLicenseDeclared: BSD-3-Clause
PackageSupplier:        Person: Arvid Norberg
PackageDownloadLocation: https://www.libtorrent.org/
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         BitTorrent engine. Ships as
                        Frameworks/libtorrent-rasterbar.2.0.dylib.
                        Built with TORRENT_USE_OPENSSL, TORRENT_SSL_PEERS;
                        SSL2/SSL3/TLS1.0/TLS1.1/DTLS1 compiled out.
```

```
PackageName:            Boost
PackageVersion:         1.9x
PackageLicenseDeclared: BSL-1.0
PackageSupplier:        Organization: Boost Community
PackageDownloadLocation: https://www.boost.org/
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         Transitive dependency of libtorrent; statically linked inside it.
                        Not a separate dylib.
```

```
PackageName:            OpenSSL
PackageVersion:         3.x
PackageLicenseDeclared: Apache-2.0
PackageSupplier:        Organization: The OpenSSL Project
PackageDownloadLocation: https://www.openssl.org/
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         TLS and crypto primitives. Ships as Frameworks/libssl.3.dylib
                        and Frameworks/libcrypto.3.dylib. Used by libtorrent, by libssh2,
                        and for AES-128-CBC HLS segment decryption.
                        NOTE: OpenSSL 3.x is Apache-2.0, not the old dual OpenSSL/SSLeay
                        licence — no advertising clause applies.
```

```
PackageName:            libssh2
PackageVersion:         1.11.x
PackageLicenseDeclared: BSD-3-Clause
PackageSupplier:        Organization: libssh2 project
PackageDownloadLocation: https://www.libssh2.org/
FilesAnalyzed:          false
PrimaryPackagePurpose:  LIBRARY
PackageComment:         SFTP transport. Ships as Frameworks/libssh2.1.dylib.
```

### 2.4 Optionally bundled tools

```
PackageName:            yt-dlp
PackageVersion:         pinned per release
PackageLicenseDeclared: Unlicense
PackageSupplier:        Organization: yt-dlp project
PackageDownloadLocation: https://github.com/yt-dlp/yt-dlp
FilesAnalyzed:          false
PrimaryPackagePurpose:  APPLICATION
PackageComment:         Resources/yt-dlp — present ONLY in builds that bundle it.
                        The macOS binary embeds a Python runtime (PSF License) and
                        further permissively-licensed components; see the yt-dlp project
                        for its own dependency list. Executed as a subprocess, not linked.
                        If your policy forbids bundled interpreters, request a build
                        without it.
```

---

## 3. System-provided, not redistributed

Linked from the operating system and therefore outside this SBOM's redistribution scope:

| Component | Source |
|---|---|
| libcurl | macOS system library / distro package |
| libsqlite3 | macOS system library (see note below) |
| Swift runtime and standard library | macOS / toolchain |
| Foundation, SwiftUI, AppKit, Network.framework, Security.framework | Apple frameworks |

> **Linux note.** GRDB requires a SQLite built with `SQLITE_ENABLE_SNAPSHOT`. Ubuntu's
> stock `libsqlite3` declares the `sqlite3_snapshot_*` symbols but omits them from the
> shared object, so Linux builds link against a vendored snapshot-enabled SQLite
> (`GOEL_SQLITE_DIR`, default `Vendor/linux/sqlite`). SQLite is public domain. If your
> deployment vendors it, add SQLite to your own downstream SBOM.

---

## 4. Relationships

```
GoelDownloader  CONTAINS         GoelApp | GoelDaemon
GoelApp         DEPENDS_ON       GoelCore, Sparkle
GoelDaemon      DEPENDS_ON       GoelCore
GoelCore        DEPENDS_ON       GRDB.swift, TorrentBridge, CurlBridge, SSHBridge
GoelCore        DEPENDS_ON       CryptoBridge, swift-crypto, swift-nio   [Linux only]
TorrentBridge   DEPENDS_ON       libtorrent-rasterbar
libtorrent      STATIC_LINK      Boost
libtorrent      DYNAMIC_LINK     OpenSSL
SSHBridge       DYNAMIC_LINK     libssh2
libssh2         DYNAMIC_LINK     OpenSSL
CurlBridge      DYNAMIC_LINK     libcurl        [system]
CryptoBridge    DYNAMIC_LINK     libcrypto      [Linux only]
```

---

## 5. Licence obligations

| Licence | Obligation on you as a licensee |
|---|---|
| BSD-3-Clause (libtorrent, libssh2) | Retain copyright notice and disclaimer in documentation. No endorsement using contributor names. |
| BSL-1.0 (Boost) | Retain notice, except in machine-executable object code. |
| Apache-2.0 (OpenSSL, swift-crypto, swift-nio) | Retain notice; no trademark grant; patent grant included. |
| MIT (GRDB, Sparkle) | Retain copyright and permission notice. |
| Unlicense (yt-dlp) | None. |

**All of these are satisfied by shipping
[`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md) alongside the application**, which
is what the product does. If you redistribute Goel° internally, keep that file with it.

None of these licences requires you to disclose your own source code, and none restricts
commercial use.

---

## 6. Provenance and integrity

- Swift package versions are pinned by `Package.resolved`, including exact git revisions,
  so a rebuild resolves the same code.
- macOS release builds are signed and notarised; local development builds are signed with
  a stable identity so macOS retains its permission grants across rebuilds.
- Where Sparkle is enabled, updates are delivered over HTTPS and verified by its EdDSA
  signature check before installation; an unsigned or mis-signed update is refused. No
  published release enables it — activation requires `SUFeedURL` and `SUPublicEDKey` in
  `Info.plist`, and none carries them — so today updating means fetching the next notarised
  artefact by hand, prompted by the built-in GitHub-Releases checker, which installs nothing
  itself.
- Native library versions track Homebrew's formulae at build time; the exact versions in
  any given release are recorded in that release's notes.

---

## 7. Vulnerability management

See [`security-questionnaire.md`](security-questionnaire.md) §7 for the full patch and
disclosure process. In summary: dependencies are monitored for advisories, security fixes
in a bundled component are rebuilt and released, and Business/Enterprise licensees are
notified by email rather than having to watch a changelog.

---

## 8. Requesting a machine-readable SBOM

SPDX 2.3 JSON or CycloneDX 1.5, generated against a specific release tag and including
resolved native-library versions and file-level checksums, is available to Business and
Enterprise licensees. Email **licensing@vinitk.dev** with the release tag and the format
your tooling needs.
