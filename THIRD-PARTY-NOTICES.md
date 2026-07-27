# Third-Party Notices

Goel° Download Manager bundles the third-party components listed below inside the
application bundle (`Goel°.app/Contents/Frameworks/` and `.../Resources/`). Each is
the property of its respective authors and is redistributed under the license shown.
This file must accompany any redistribution of the application.

| Component | Version | License | Where it lives in the app |
|---|---|---|---|
| [libtorrent-rasterbar](https://www.libtorrent.org/) | 2.0.x | BSD-3-Clause | `Frameworks/libtorrent-rasterbar.2.0.dylib` |
| [Boost](https://www.boost.org/) | 1.9x | BSL-1.0 | statically linked inside libtorrent |
| [OpenSSL](https://www.openssl.org/) | 3.x | Apache-2.0 | `Frameworks/libssl.3.dylib`, `libcrypto.3.dylib` |
| [libssh2](https://www.libssh2.org/) | 1.11.x | BSD-3-Clause | `Frameworks/libssh2.1.dylib` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29.3 | MIT | statically linked into the executable |
| [Sparkle](https://sparkle-project.org/) | 2.9.3 | MIT | `Frameworks/Sparkle.framework` |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | pinned | The Unlicense (the frozen binary also embeds GPL-2.0-or-later components — see [§yt-dlp](#yt-dlp--the-unlicense)) | `Resources/yt-dlp` (only if bundled) |
| [FFmpeg](https://ffmpeg.org/) | per release | LGPL-2.1-or-later | `Resources/ffmpeg` (only if bundled) |

FFmpeg and yt-dlp are the **copyleft** components here, and they are the two whose licences
ask for more than attribution. If you redistribute the application you must also satisfy
[FFmpeg's terms](#ffmpeg--lgpl-21-or-later) and
[yt-dlp's](#embedded-components--the-part-the-unlicense-does-not-cover) — the licence texts
are reproduced in [Appendix A](#appendix-a--gnu-lesser-general-public-license-version-21)
and [Appendix B](#appendix-b--gnu-general-public-license-version-2), and the written source
offers are in the respective sections, so shipping this file alongside the `.app` is what
discharges the obligation.

System libraries linked from macOS (libcurl, libsqlite3, the Swift runtime, and
Apple frameworks) are provided by the operating system and are not redistributed here.

### The Linux daemon tarball

`goel-daemon-<version>-linux-<arch>.tar.gz` redistributes a **different** set, because Linux
supplies neither the Swift runtime nor a libtorrent whose SONAME is stable across releases.
This file travels inside that tarball, and the components in it are:

| Component | License | Where it lives in the tarball |
|---|---|---|
| [Swift runtime](https://swift.org/) | Apache-2.0 with Runtime Library Exception | `lib/libswift*.so`, `lib/libFoundation*.so`, `lib/libdispatch.so`, `lib/libBlocksRuntime.so` — notices in `SWIFT-RUNTIME-LICENSE.txt` / `SWIFT-RUNTIME-NOTICE.txt` |
| [libtorrent-rasterbar](https://www.libtorrent.org/) | BSD-3-Clause | `lib/libtorrent-rasterbar.so.2.x` |
| [Boost](https://www.boost.org/) | BSL-1.0 | `lib/libboost_*.so`, when not linked statically inside libtorrent |
| [SQLite](https://sqlite.org/) | Public domain | `lib/libsqlite3.so`, built from the amalgamation with `SQLITE_ENABLE_SNAPSHOT` |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) | MIT | `lib/libxml2.so.2` — required by Foundation's XML support |
| [ICU](https://icu.unicode.org/) | Unicode-3.0 | `lib/libicuuc.so.NN`, `lib/libicudata.so.NN` — required by libxml2 |

libxml2 and ICU are bundled for the same reason libtorrent is: their SONAMEs encode an
upstream version that moves between distribution releases (libxml2 is `.so.2` on Ubuntu
24.04 and `.so.16` on 26.04), so a tarball that left them to the distribution could not
start on a release other than the one it was built on.

OpenSSL, libcurl, libssh2 and ffmpeg are **not** redistributed in the tarball — those come
from the operator's own distribution, which is also what keeps them patched. The
frozen-at-build-time caveat below therefore applies to the table above, not to those.

**Determining exact versions for a given build.** GRDB and Sparkle are pinned in
`Package.resolved` and the versions above are exact. The C libraries are sourced from
Homebrew at build time, so their precise version is a property of the build machine rather
than of this repository — the exact set is recorded in the per-release SBOM, which is
available on request and supplied to commercial licensees. To inspect a build you already
have, run `otool -L "/Applications/Goel°.app/Contents/MacOS/GoelDownloader"` and check the
compatibility versions of the vendored dylibs in `Contents/Frameworks/`.

**Patching.** These components are frozen at build time and there is no independent update
path — a CVE in any of them requires a new Goel° release. The review cadence and patch
window are committed to in [SECURITY.md](SECURITY.md#vendored-dependency-cve-policy).
FFmpeg is the exception in both directions: it is a separate executable rather than linked
code, so a user who wants a newer one can drop it in themselves (Settings → Media tools →
"ffmpeg path") without waiting for a release — which is also what LGPL-2.1 requires of us.
A CVE in it is still reviewed and shipped on the same cadence as everything else.

---

## Licence compatibility

Every bundled component's *own* licence is **permissive** except FFmpeg's, and none of them
carries a field-of-use restriction. FFmpeg is **weak copyleft** (LGPL-2.1-or-later): its
terms attach to FFmpeg itself, not to the larger work, provided it stays at arm's length —
which here means a separate executable the user can replace, never code linked into the
app. yt-dlp's own source is public-domain, but the frozen binary embeds a GPL-2.0-or-later
library (mutagen); the same arm's-length argument applies, and the same obligations follow
for that component. Those two are called out separately below because they are the entries
that oblige a redistributor to do more than reproduce a notice:

| Component | Licence | Copyleft? | Attribution required? | Compatible with relicensing Goel°? |
|---|---|---|---|---|
| libtorrent-rasterbar | BSD-3-Clause | No | Yes — notice + disclaimer | Yes |
| Boost | BSL-1.0 | No | Yes — but not for binary-only distribution | Yes |
| OpenSSL | Apache-2.0 | No | Yes — notice + NOTICE file | Yes |
| libssh2 | BSD-3-Clause | No | Yes — notice + disclaimer | Yes |
| GRDB.swift | MIT | No | Yes — notice | Yes |
| Sparkle | MIT | No | Yes — notice | Yes |
| yt-dlp (own source) | The Unlicense | No | No (public domain dedication) | Yes |
| yt-dlp (embedded mutagen) | GPL-2.0-or-later | Strong — binds mutagen only | Yes — notice, licence text **and** source access | Yes, while it stays a separate replaceable executable |
| FFmpeg | LGPL-2.1-or-later | Weak — binds FFmpeg only | Yes — notice, licence text **and** source access | Yes, while it stays a separate replaceable executable |

This matters because Goel° itself moved from MIT to the
[PolyForm Noncommercial License 1.0.0](LICENSE), and is additionally offered under a
[paid commercial licence](LICENSE-COMMERCIAL.md). Permissive dependencies impose no
restriction on the licence of the larger work, and FFmpeg's LGPL terms reach only FFmpeg
because it is executed rather than linked, so:

- Goel° could be relicensed from MIT to PolyForm without any dependency's permission.
- Goel° can be distributed to commercial licensees under negotiated proprietary terms.
- The only obligation the permissive licences impose is **attribution** — which is what
  this file is for. FFmpeg additionally requires that its licence text and its
  corresponding source be available to whoever receives the binary; both are provided
  below. This file must accompany any redistribution of the application.

Two clauses are worth calling out explicitly, because reviewers ask about them:

- **BSD-3-Clause (libtorrent, libssh2)** carries a no-endorsement clause. The names of
  those projects and their authors are not used to endorse or promote Goel°, and must not
  be by anyone redistributing it.
- **Apache-2.0 (OpenSSL)** carries a patent grant with a defensive-termination clause, and
  requires that modifications be marked. OpenSSL is bundled unmodified.

**Adding a copyleft dependency the application *links* would break this.** A GPL or AGPL
library linked into the executable would constrain the licence of the whole application;
an LGPL one would have to be kept at arm's length in a separate, user-replaceable process
exactly as FFmpeg is, and would drag the same source-availability duty along with it. This
is a hard constraint on contributions — see
[CONTRIBUTING.md](CONTRIBUTING.md#before-you-write-code).

Bundling is a different question from linking, and the distinction is doing real work
here. `Resources/yt-dlp` is a standalone executable that happens to be shipped in the same
folder: Goel° spawns it as a subprocess, shares no address space with it, and works
without it. That is mere aggregation, so its embedded GPL-2.0-or-later components do not
reach the rest of the application — the same argument already recorded for FFmpeg below.
What mere aggregation does *not* waive is the duty owed for the GPL'd work itself, which
is why [Appendix B](#appendix-b--gnu-general-public-license-version-2) exists and why the
[§yt-dlp](#embedded-components--the-part-the-unlicense-does-not-cover) section carries a
source offer. Anything that would *link* GPL code into the app, or make Goel° depend on
yt-dlp to function, breaks the argument and is not acceptable.

---

## libtorrent-rasterbar — BSD-3-Clause

Copyright © 2003-2024, Arvid Norberg. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this
   list of conditions and the following disclaimer in the documentation and/or
   other materials provided with the distribution.
3. Neither the name of the author nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific prior
   written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

---

## Boost — Boost Software License 1.0

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by this
license (the "Software") to use, reproduce, display, distribute, execute, and
transmit the Software, and to prepare derivative works of the Software, and to
permit third-parties to whom the Software is furnished to do so, all subject to the
following:

The copyright notices in the Software and this entire statement, including the above
license grant, this restriction and the following disclaimer, must be included in
all copies of the Software, in whole or in part, and all derivative works of the
Software, unless such copies or derivative works are solely in the form of
machine-executable object code generated by a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT
HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER
LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## OpenSSL — Apache License 2.0

Copyright © 1998-2024 The OpenSSL Project Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
these files except in compliance with the License. You may obtain a copy of the
License at:

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.

The full Apache License 2.0 text is available at the URL above and is incorporated
here by reference. A copy is included with the OpenSSL source distribution.

---

## libssh2 — BSD-3-Clause

Copyright © 2004-2019 Sara Golemon <sarag@libssh2.org>
Copyright © 2005,2006 Mikhail Gusarov <dottedmag@dottedmag.net>
Copyright © 2006-2007 The Written Word, Inc.
Copyright © 2007 Eli Fant <elifantu@mail.ru>
Copyright © 2009-2022 Daniel Stenberg
Copyright © 2008, 2009 Simon Josefsson
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

  Redistributions of source code must retain the above copyright notice, this list
  of conditions and the following disclaimer.

  Redistributions in binary form must reproduce the above copyright notice, this
  list of conditions and the following disclaimer in the documentation and/or other
  materials provided with the distribution.

  Neither the name of the copyright holder nor the names of any other contributors
  may be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.

---

## GRDB.swift — MIT

Copyright © 2015-2024 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the
Software without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so, subject to the
following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Sparkle — MIT

Copyright © 2006-2024 Andy Matuschak and the Sparkle project contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the
Software without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
and to permit persons to whom the Software is furnished to do so, subject to the
following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Sparkle also includes portions under the BSD and other permissive licenses; see the
Sparkle project for the complete list.

---

## yt-dlp — The Unlicense

This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.

In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to the
detriment of our heirs and successors. We intend this dedication to be an overt act
of relinquishment in perpetuity of all present and future rights to this software
under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR
ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

### Embedded components — the part the Unlicense does not cover

The Unlicense above covers yt-dlp's *own* source. It does not cover what the
PyInstaller-frozen `yt-dlp_macos` binary carries inside it, and that is not all
permissive. As of the pinned build the frozen binary reports these embedded libraries
(`yt-dlp --verbose` prints the list):

| Embedded component | Licence |
|---|---|
| CPython runtime | PSF License 2.0 |
| [mutagen](https://github.com/quodlibet/mutagen) | **GPL-2.0-or-later** |
| [pycryptodomex](https://github.com/Legrandin/pycryptodome) | BSD-2-Clause + Public Domain (Unlicense) |
| [certifi](https://github.com/certifi/python-certifi) | MPL-2.0 |
| [requests](https://github.com/psf/requests), [urllib3](https://github.com/urllib3/urllib3) | Apache-2.0 / MIT |
| [brotli](https://github.com/google/brotli), [websockets](https://github.com/python-websockets/websockets), [curl_cffi](https://github.com/lexiforest/curl_cffi) | MIT / BSD-3-Clause |

**mutagen is GPL-2.0-or-later**, which is copyleft and is not GPL-compatible with
PolyForm Noncommercial 1.0.0. That does not make shipping it a violation, because Goel°
does not link it: `Resources/yt-dlp` is a separate executable, spawned as a subprocess,
and the application runs without it — set `BUNDLE_YTDLP=0` at build time and the
"Resolve with yt-dlp" affordance simply stays hidden. This is mere aggregation, the same
position recorded for FFmpeg below, and it is deliberately *not* the position taken for a
GPL-configured FFmpeg: `Scripts/fetch_ffmpeg.sh` refuses one, because ffmpeg would be the
component doing the media work rather than an optional resolver.

What mere aggregation does not do is discharge the obligations owed for the GPL'd work
itself. So:

- The GPL-2.0 licence text is reproduced verbatim in
  [Appendix B](#appendix-b--gnu-general-public-license-version-2). A hyperlink is not a
  copy, exactly as argued for LGPL-2.1 in Appendix A.
- **Corresponding source.** mutagen's complete source for the version embedded in the
  pinned yt-dlp build is published at <https://github.com/quodlibet/mutagen>, tagged by
  release. For three years from the date you received this application, the maintainer
  will also supply that source on a physical medium for no more than the cost of
  distribution — write to `licensing@vinitk.dev` quoting the application version, and
  the `yt-dlp --verbose` "Optional libraries" line identifies the exact mutagen version
  in your copy.
- Users may run their own yt-dlp instead of the bundled one. `YtDlpResolver` prefers the
  copy in `Contents/Resources/` and otherwise looks in `/opt/homebrew/bin`,
  `/usr/local/bin` and `~/.local/bin`, so building with `BUNDLE_YTDLP=0` (or replacing
  that file and re-signing the bundle) substitutes a build of your own.

---

## FFmpeg — LGPL-2.1-or-later

- Upstream: https://ffmpeg.org/
- Licence: GNU Lesser General Public License v2.1 or later (LGPL-2.1-or-later)
- Used for: converting finished downloads between containers and extracting audio
  tracks; HLS remux on the Linux daemon.
- Configuration: built with `--disable-gpl --disable-nonfree`. No GPL-only
  components (x264, x265, libfdk_aac, …) are included.
- LGPL relinking: FFmpeg is bundled as a SEPARATE executable at
  `Goel°.app/Contents/Resources/ffmpeg`, not statically linked into the app. Any
  user may replace it, or point Goel° at their own build via
  Settings → Media tools → "ffmpeg path".
- Full licence text: reproduced verbatim in this file as
  [Appendix A](#appendix-a--gnu-lesser-general-public-license-version-21). It is the
  same text FFmpeg ships as `COPYING.LGPLv2.1`; see also
  https://www.ffmpeg.org/legal.html. A URL is *not* sufficient on its own — LGPL-2.1
  requires the licence to travel with the binary, which is why the text is inlined here
  rather than linked.

### Corresponding source — the part a URL does not satisfy

LGPL-2.1 §4 governs distributing the library in object-code form. It is not discharged by
attribution: whoever hands out the binary must also hand out, or offer, the complete
corresponding source. Two things make that tractable here.

**FFmpeg is bundled unmodified.** Nothing in this repository patches it. The corresponding
source is therefore the upstream release tarball for the exact version the shipped binary
reports, built with the exact configure line it reports. Both come out of the binary
itself, so any recipient can identify their own corresponding source without asking:

```
"/Applications/Goel°.app/Contents/Resources/ffmpeg" -hide_banner -version
```

The first line gives the version (`ffmpeg version 7.1 …`, upstream tarball
`https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz`), and the `configuration:` line gives the
exact build flags. `Scripts/fetch_ffmpeg.sh` reads the same banner to enforce the LGPL
configuration, so it is the authoritative record for a given build.

**Written offer, valid for three years.** For every Goel° release that bundles FFmpeg, the
author hereby offers to any third party in possession of that binary — for a period of no
less than three years from the date the release was distributed — the complete
corresponding source of the bundled FFmpeg, on a medium customarily used for software
interchange, for no more than the cost of performing the distribution. Write to
**licensing@vinitk.dev** quoting the Goel° version. This offer is made by the author, is
not conditional on any licence being purchased, and travels with the binary: it covers
copies redistributed by licensees just as it covers copies downloaded from us.

**Release-process requirement.** Any release that ships an ffmpeg must publish the matching
upstream source tarball and its SHA-256 as an asset next to the `.dmg`, so that the source
is reachable "from the same place" as the binary in the sense of LGPL-2.1 §4 and the offer
above is a belt-and-braces fallback rather than the only route.

**If you redistribute Goel° yourself** — an internal fleet deployment under a commercial
licence counts — you are redistributing FFmpeg too, and §4 binds you as well as us. Ship
this file with the application, unmodified: it carries the licence text (Appendix A), the
identification of the corresponding source, and the standing offer above, which together
are what §4 asks you to accompany the binary with. A build with the bundled ffmpeg removed
(`FFMPEG_OPTIONAL=1`) carries none of these obligations.

FFmpeg is dual-configurable — LGPL-2.1+ by default, or GPL-2.0+/GPL-3.0+ with
`--enable-gpl` (and non-redistributable with `--enable-nonfree`). Goel° ships
under PolyForm Noncommercial 1.0.0, which is **not** GPL-compatible, so
redistributing a GPL-configured ffmpeg inside the .app would be a licence
violation. `Scripts/fetch_ffmpeg.sh` therefore enforces the LGPL configuration by
parsing the binary's own `ffmpeg -version` configure banner and refusing any
build containing `--enable-gpl` or `--enable-nonfree`.

If a GPL build is ever knowingly shipped (`FFMPEG_ALLOW_GPL=1`), this entry must
be changed to GPL-2.0-or-later AND the project licence re-examined first.

---

## Appendix A — GNU Lesser General Public License, version 2.1

Reproduced verbatim, because LGPL-2.1 requires a copy of the licence to accompany the
binary it covers and a hyperlink is not a copy. This is the text of `COPYING.LGPLv2.1`
as distributed with FFmpeg. It applies to the bundled `Resources/ffmpeg` only — the rest
of Goel° is licensed as described in [LICENSE](LICENSE).

```text
                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999

 Copyright (C) 1991, 1999 Free Software Foundation, Inc.
 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

[This is the first released version of the Lesser GPL.  It also counts
 as the successor of the GNU Library Public License, version 2, hence
 the version number 2.1.]

                            Preamble

  The licenses for most software are designed to take away your
freedom to share and change it.  By contrast, the GNU General Public
Licenses are intended to guarantee your freedom to share and change
free software--to make sure the software is free for all its users.

  This license, the Lesser General Public License, applies to some
specially designated software packages--typically libraries--of the
Free Software Foundation and other authors who decide to use it.  You
can use it too, but we suggest you first think carefully about whether
this license or the ordinary General Public License is the better
strategy to use in any particular case, based on the explanations below.

  When we speak of free software, we are referring to freedom of use,
not price.  Our General Public Licenses are designed to make sure that
you have the freedom to distribute copies of free software (and charge
for this service if you wish); that you receive source code or can get
it if you want it; that you can change the software and use pieces of
it in new free programs; and that you are informed that you can do
these things.

  To protect your rights, we need to make restrictions that forbid
distributors to deny you these rights or to ask you to surrender these
rights.  These restrictions translate to certain responsibilities for
you if you distribute copies of the library or if you modify it.

  For example, if you distribute copies of the library, whether gratis
or for a fee, you must give the recipients all the rights that we gave
you.  You must make sure that they, too, receive or can get the source
code.  If you link other code with the library, you must provide
complete object files to the recipients, so that they can relink them
with the library after making changes to the library and recompiling
it.  And you must show them these terms so they know their rights.

  We protect your rights with a two-step method: (1) we copyright the
library, and (2) we offer you this license, which gives you legal
permission to copy, distribute and/or modify the library.

  To protect each distributor, we want to make it very clear that
there is no warranty for the free library.  Also, if the library is
modified by someone else and passed on, the recipients should know
that what they have is not the original version, so that the original
author's reputation will not be affected by problems that might be
introduced by others.

  Finally, software patents pose a constant threat to the existence of
any free program.  We wish to make sure that a company cannot
effectively restrict the users of a free program by obtaining a
restrictive license from a patent holder.  Therefore, we insist that
any patent license obtained for a version of the library must be
consistent with the full freedom of use specified in this license.

  Most GNU software, including some libraries, is covered by the
ordinary GNU General Public License.  This license, the GNU Lesser
General Public License, applies to certain designated libraries, and
is quite different from the ordinary General Public License.  We use
this license for certain libraries in order to permit linking those
libraries into non-free programs.

  When a program is linked with a library, whether statically or using
a shared library, the combination of the two is legally speaking a
combined work, a derivative of the original library.  The ordinary
General Public License therefore permits such linking only if the
entire combination fits its criteria of freedom.  The Lesser General
Public License permits more lax criteria for linking other code with
the library.

  We call this license the "Lesser" General Public License because it
does Less to protect the user's freedom than the ordinary General
Public License.  It also provides other free software developers Less
of an advantage over competing non-free programs.  These disadvantages
are the reason we use the ordinary General Public License for many
libraries.  However, the Lesser license provides advantages in certain
special circumstances.

  For example, on rare occasions, there may be a special need to
encourage the widest possible use of a certain library, so that it becomes
a de-facto standard.  To achieve this, non-free programs must be
allowed to use the library.  A more frequent case is that a free
library does the same job as widely used non-free libraries.  In this
case, there is little to gain by limiting the free library to free
software only, so we use the Lesser General Public License.

  In other cases, permission to use a particular library in non-free
programs enables a greater number of people to use a large body of
free software.  For example, permission to use the GNU C Library in
non-free programs enables many more people to use the whole GNU
operating system, as well as its variant, the GNU/Linux operating
system.

  Although the Lesser General Public License is Less protective of the
users' freedom, it does ensure that the user of a program that is
linked with the Library has the freedom and the wherewithal to run
that program using a modified version of the Library.

  The precise terms and conditions for copying, distribution and
modification follow.  Pay close attention to the difference between a
"work based on the library" and a "work that uses the library".  The
former contains code derived from the library, whereas the latter must
be combined with the library in order to run.

                  GNU LESSER GENERAL PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. This License Agreement applies to any software library or other
program which contains a notice placed by the copyright holder or
other authorized party saying it may be distributed under the terms of
this Lesser General Public License (also called "this License").
Each licensee is addressed as "you".

  A "library" means a collection of software functions and/or data
prepared so as to be conveniently linked with application programs
(which use some of those functions and data) to form executables.

  The "Library", below, refers to any such software library or work
which has been distributed under these terms.  A "work based on the
Library" means either the Library or any derivative work under
copyright law: that is to say, a work containing the Library or a
portion of it, either verbatim or with modifications and/or translated
straightforwardly into another language.  (Hereinafter, translation is
included without limitation in the term "modification".)

  "Source code" for a work means the preferred form of the work for
making modifications to it.  For a library, complete source code means
all the source code for all modules it contains, plus any associated
interface definition files, plus the scripts used to control compilation
and installation of the library.

  Activities other than copying, distribution and modification are not
covered by this License; they are outside its scope.  The act of
running a program using the Library is not restricted, and output from
such a program is covered only if its contents constitute a work based
on the Library (independent of the use of the Library in a tool for
writing it).  Whether that is true depends on what the Library does
and what the program that uses the Library does.

  1. You may copy and distribute verbatim copies of the Library's
complete source code as you receive it, in any medium, provided that
you conspicuously and appropriately publish on each copy an
appropriate copyright notice and disclaimer of warranty; keep intact
all the notices that refer to this License and to the absence of any
warranty; and distribute a copy of this License along with the
Library.

  You may charge a fee for the physical act of transferring a copy,
and you may at your option offer warranty protection in exchange for a
fee.

  2. You may modify your copy or copies of the Library or any portion
of it, thus forming a work based on the Library, and copy and
distribute such modifications or work under the terms of Section 1
above, provided that you also meet all of these conditions:

    a) The modified work must itself be a software library.

    b) You must cause the files modified to carry prominent notices
    stating that you changed the files and the date of any change.

    c) You must cause the whole of the work to be licensed at no
    charge to all third parties under the terms of this License.

    d) If a facility in the modified Library refers to a function or a
    table of data to be supplied by an application program that uses
    the facility, other than as an argument passed when the facility
    is invoked, then you must make a good faith effort to ensure that,
    in the event an application does not supply such function or
    table, the facility still operates, and performs whatever part of
    its purpose remains meaningful.

    (For example, a function in a library to compute square roots has
    a purpose that is entirely well-defined independent of the
    application.  Therefore, Subsection 2d requires that any
    application-supplied function or table used by this function must
    be optional: if the application does not supply it, the square
    root function must still compute square roots.)

These requirements apply to the modified work as a whole.  If
identifiable sections of that work are not derived from the Library,
and can be reasonably considered independent and separate works in
themselves, then this License, and its terms, do not apply to those
sections when you distribute them as separate works.  But when you
distribute the same sections as part of a whole which is a work based
on the Library, the distribution of the whole must be on the terms of
this License, whose permissions for other licensees extend to the
entire whole, and thus to each and every part regardless of who wrote
it.

Thus, it is not the intent of this section to claim rights or contest
your rights to work written entirely by you; rather, the intent is to
exercise the right to control the distribution of derivative or
collective works based on the Library.

In addition, mere aggregation of another work not based on the Library
with the Library (or with a work based on the Library) on a volume of
a storage or distribution medium does not bring the other work under
the scope of this License.

  3. You may opt to apply the terms of the ordinary GNU General Public
License instead of this License to a given copy of the Library.  To do
this, you must alter all the notices that refer to this License, so
that they refer to the ordinary GNU General Public License, version 2,
instead of to this License.  (If a newer version than version 2 of the
ordinary GNU General Public License has appeared, then you can specify
that version instead if you wish.)  Do not make any other change in
these notices.

  Once this change is made in a given copy, it is irreversible for
that copy, so the ordinary GNU General Public License applies to all
subsequent copies and derivative works made from that copy.

  This option is useful when you wish to copy part of the code of
the Library into a program that is not a library.

  4. You may copy and distribute the Library (or a portion or
derivative of it, under Section 2) in object code or executable form
under the terms of Sections 1 and 2 above provided that you accompany
it with the complete corresponding machine-readable source code, which
must be distributed under the terms of Sections 1 and 2 above on a
medium customarily used for software interchange.

  If distribution of object code is made by offering access to copy
from a designated place, then offering equivalent access to copy the
source code from the same place satisfies the requirement to
distribute the source code, even though third parties are not
compelled to copy the source along with the object code.

  5. A program that contains no derivative of any portion of the
Library, but is designed to work with the Library by being compiled or
linked with it, is called a "work that uses the Library".  Such a
work, in isolation, is not a derivative work of the Library, and
therefore falls outside the scope of this License.

  However, linking a "work that uses the Library" with the Library
creates an executable that is a derivative of the Library (because it
contains portions of the Library), rather than a "work that uses the
library".  The executable is therefore covered by this License.
Section 6 states terms for distribution of such executables.

  When a "work that uses the Library" uses material from a header file
that is part of the Library, the object code for the work may be a
derivative work of the Library even though the source code is not.
Whether this is true is especially significant if the work can be
linked without the Library, or if the work is itself a library.  The
threshold for this to be true is not precisely defined by law.

  If such an object file uses only numerical parameters, data
structure layouts and accessors, and small macros and small inline
functions (ten lines or less in length), then the use of the object
file is unrestricted, regardless of whether it is legally a derivative
work.  (Executables containing this object code plus portions of the
Library will still fall under Section 6.)

  Otherwise, if the work is a derivative of the Library, you may
distribute the object code for the work under the terms of Section 6.
Any executables containing that work also fall under Section 6,
whether or not they are linked directly with the Library itself.

  6. As an exception to the Sections above, you may also combine or
link a "work that uses the Library" with the Library to produce a
work containing portions of the Library, and distribute that work
under terms of your choice, provided that the terms permit
modification of the work for the customer's own use and reverse
engineering for debugging such modifications.

  You must give prominent notice with each copy of the work that the
Library is used in it and that the Library and its use are covered by
this License.  You must supply a copy of this License.  If the work
during execution displays copyright notices, you must include the
copyright notice for the Library among them, as well as a reference
directing the user to the copy of this License.  Also, you must do one
of these things:

    a) Accompany the work with the complete corresponding
    machine-readable source code for the Library including whatever
    changes were used in the work (which must be distributed under
    Sections 1 and 2 above); and, if the work is an executable linked
    with the Library, with the complete machine-readable "work that
    uses the Library", as object code and/or source code, so that the
    user can modify the Library and then relink to produce a modified
    executable containing the modified Library.  (It is understood
    that the user who changes the contents of definitions files in the
    Library will not necessarily be able to recompile the application
    to use the modified definitions.)

    b) Use a suitable shared library mechanism for linking with the
    Library.  A suitable mechanism is one that (1) uses at run time a
    copy of the library already present on the user's computer system,
    rather than copying library functions into the executable, and (2)
    will operate properly with a modified version of the library, if
    the user installs one, as long as the modified version is
    interface-compatible with the version that the work was made with.

    c) Accompany the work with a written offer, valid for at
    least three years, to give the same user the materials
    specified in Subsection 6a, above, for a charge no more
    than the cost of performing this distribution.

    d) If distribution of the work is made by offering access to copy
    from a designated place, offer equivalent access to copy the above
    specified materials from the same place.

    e) Verify that the user has already received a copy of these
    materials or that you have already sent this user a copy.

  For an executable, the required form of the "work that uses the
Library" must include any data and utility programs needed for
reproducing the executable from it.  However, as a special exception,
the materials to be distributed need not include anything that is
normally distributed (in either source or binary form) with the major
components (compiler, kernel, and so on) of the operating system on
which the executable runs, unless that component itself accompanies
the executable.

  It may happen that this requirement contradicts the license
restrictions of other proprietary libraries that do not normally
accompany the operating system.  Such a contradiction means you cannot
use both them and the Library together in an executable that you
distribute.

  7. You may place library facilities that are a work based on the
Library side-by-side in a single library together with other library
facilities not covered by this License, and distribute such a combined
library, provided that the separate distribution of the work based on
the Library and of the other library facilities is otherwise
permitted, and provided that you do these two things:

    a) Accompany the combined library with a copy of the same work
    based on the Library, uncombined with any other library
    facilities.  This must be distributed under the terms of the
    Sections above.

    b) Give prominent notice with the combined library of the fact
    that part of it is a work based on the Library, and explaining
    where to find the accompanying uncombined form of the same work.

  8. You may not copy, modify, sublicense, link with, or distribute
the Library except as expressly provided under this License.  Any
attempt otherwise to copy, modify, sublicense, link with, or
distribute the Library is void, and will automatically terminate your
rights under this License.  However, parties who have received copies,
or rights, from you under this License will not have their licenses
terminated so long as such parties remain in full compliance.

  9. You are not required to accept this License, since you have not
signed it.  However, nothing else grants you permission to modify or
distribute the Library or its derivative works.  These actions are
prohibited by law if you do not accept this License.  Therefore, by
modifying or distributing the Library (or any work based on the
Library), you indicate your acceptance of this License to do so, and
all its terms and conditions for copying, distributing or modifying
the Library or works based on it.

  10. Each time you redistribute the Library (or any work based on the
Library), the recipient automatically receives a license from the
original licensor to copy, distribute, link with or modify the Library
subject to these terms and conditions.  You may not impose any further
restrictions on the recipients' exercise of the rights granted herein.
You are not responsible for enforcing compliance by third parties with
this License.

  11. If, as a consequence of a court judgment or allegation of patent
infringement or for any other reason (not limited to patent issues),
conditions are imposed on you (whether by court order, agreement or
otherwise) that contradict the conditions of this License, they do not
excuse you from the conditions of this License.  If you cannot
distribute so as to satisfy simultaneously your obligations under this
License and any other pertinent obligations, then as a consequence you
may not distribute the Library at all.  For example, if a patent
license would not permit royalty-free redistribution of the Library by
all those who receive copies directly or indirectly through you, then
the only way you could satisfy both it and this License would be to
refrain entirely from distribution of the Library.

If any portion of this section is held invalid or unenforceable under any
particular circumstance, the balance of the section is intended to apply,
and the section as a whole is intended to apply in other circumstances.

It is not the purpose of this section to induce you to infringe any
patents or other property right claims or to contest validity of any
such claims; this section has the sole purpose of protecting the
integrity of the free software distribution system which is
implemented by public license practices.  Many people have made
generous contributions to the wide range of software distributed
through that system in reliance on consistent application of that
system; it is up to the author/donor to decide if he or she is willing
to distribute software through any other system and a licensee cannot
impose that choice.

This section is intended to make thoroughly clear what is believed to
be a consequence of the rest of this License.

  12. If the distribution and/or use of the Library is restricted in
certain countries either by patents or by copyrighted interfaces, the
original copyright holder who places the Library under this License may add
an explicit geographical distribution limitation excluding those countries,
so that distribution is permitted only in or among countries not thus
excluded.  In such case, this License incorporates the limitation as if
written in the body of this License.

  13. The Free Software Foundation may publish revised and/or new
versions of the Lesser General Public License from time to time.
Such new versions will be similar in spirit to the present version,
but may differ in detail to address new problems or concerns.

Each version is given a distinguishing version number.  If the Library
specifies a version number of this License which applies to it and
"any later version", you have the option of following the terms and
conditions either of that version or of any later version published by
the Free Software Foundation.  If the Library does not specify a
license version number, you may choose any version ever published by
the Free Software Foundation.

  14. If you wish to incorporate parts of the Library into other free
programs whose distribution conditions are incompatible with these,
write to the author to ask for permission.  For software which is
copyrighted by the Free Software Foundation, write to the Free
Software Foundation; we sometimes make exceptions for this.  Our
decision will be guided by the two goals of preserving the free status
of all derivatives of our free software and of promoting the sharing
and reuse of software generally.

                            NO WARRANTY

  15. BECAUSE THE LIBRARY IS LICENSED FREE OF CHARGE, THERE IS NO
WARRANTY FOR THE LIBRARY, TO THE EXTENT PERMITTED BY APPLICABLE LAW.
EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR
OTHER PARTIES PROVIDE THE LIBRARY "AS IS" WITHOUT WARRANTY OF ANY
KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE.  THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE
LIBRARY IS WITH YOU.  SHOULD THE LIBRARY PROVE DEFECTIVE, YOU ASSUME
THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.

  16. IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN
WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY
AND/OR REDISTRIBUTE THE LIBRARY AS PERMITTED ABOVE, BE LIABLE TO YOU
FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR
CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE
LIBRARY (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE LIBRARY TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
DAMAGES.

                     END OF TERMS AND CONDITIONS

           How to Apply These Terms to Your New Libraries

  If you develop a new library, and you want it to be of the greatest
possible use to the public, we recommend making it free software that
everyone can redistribute and change.  You can do so by permitting
redistribution under these terms (or, alternatively, under the terms of the
ordinary General Public License).

  To apply these terms, attach the following notices to the library.  It is
safest to attach them to the start of each source file to most effectively
convey the exclusion of warranty; and each file should have at least the
"copyright" line and a pointer to where the full notice is found.

    <one line to give the library's name and a brief idea of what it does.>
    Copyright (C) <year>  <name of author>

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

Also add information on how to contact you by electronic and paper mail.

You should also get your employer (if you work as a programmer) or your
school, if any, to sign a "copyright disclaimer" for the library, if
necessary.  Here is a sample; alter the names:

  Yoyodyne, Inc., hereby disclaims all copyright interest in the
  library `Frob' (a library for tweaking knobs) written by James Random Hacker.

  <signature of Ty Coon>, 1 April 1990
  Ty Coon, President of Vice

That's all there is to it!
```

---

## Appendix B — GNU General Public License, version 2

Reproduced verbatim, because GPL-2.0 requires a copy of the licence to accompany the
binary it covers and a hyperlink is not a copy — the same standard applied to LGPL-2.1 in
Appendix A. This is the FSF's text of `gpl-2.0.txt`. It applies to the GPL-2.0-or-later
components embedded in the bundled `Resources/yt-dlp` (mutagen) only — yt-dlp's own source
is under the Unlicense, and the rest of Goel° is licensed as described in
[LICENSE](LICENSE).

```text
                    GNU GENERAL PUBLIC LICENSE
                       Version 2, June 1991

 Copyright (C) 1989, 1991 Free Software Foundation, Inc.,
 <https://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

                            Preamble

  The licenses for most software are designed to take away your
freedom to share and change it.  By contrast, the GNU General Public
License is intended to guarantee your freedom to share and change free
software--to make sure the software is free for all its users.  This
General Public License applies to most of the Free Software
Foundation's software and to any other program whose authors commit to
using it.  (Some other Free Software Foundation software is covered by
the GNU Lesser General Public License instead.)  You can apply it to
your programs, too.

  When we speak of free software, we are referring to freedom, not
price.  Our General Public Licenses are designed to make sure that you
have the freedom to distribute copies of free software (and charge for
this service if you wish), that you receive source code or can get it
if you want it, that you can change the software or use pieces of it
in new free programs; and that you know you can do these things.

  To protect your rights, we need to make restrictions that forbid
anyone to deny you these rights or to ask you to surrender the rights.
These restrictions translate to certain responsibilities for you if you
distribute copies of the software, or if you modify it.

  For example, if you distribute copies of such a program, whether
gratis or for a fee, you must give the recipients all the rights that
you have.  You must make sure that they, too, receive or can get the
source code.  And you must show them these terms so they know their
rights.

  We protect your rights with two steps: (1) copyright the software, and
(2) offer you this license which gives you legal permission to copy,
distribute and/or modify the software.

  Also, for each author's protection and ours, we want to make certain
that everyone understands that there is no warranty for this free
software.  If the software is modified by someone else and passed on, we
want its recipients to know that what they have is not the original, so
that any problems introduced by others will not reflect on the original
authors' reputations.

  Finally, any free program is threatened constantly by software
patents.  We wish to avoid the danger that redistributors of a free
program will individually obtain patent licenses, in effect making the
program proprietary.  To prevent this, we have made it clear that any
patent must be licensed for everyone's free use or not licensed at all.

  The precise terms and conditions for copying, distribution and
modification follow.

                    GNU GENERAL PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. This License applies to any program or other work which contains
a notice placed by the copyright holder saying it may be distributed
under the terms of this General Public License.  The "Program", below,
refers to any such program or work, and a "work based on the Program"
means either the Program or any derivative work under copyright law:
that is to say, a work containing the Program or a portion of it,
either verbatim or with modifications and/or translated into another
language.  (Hereinafter, translation is included without limitation in
the term "modification".)  Each licensee is addressed as "you".

Activities other than copying, distribution and modification are not
covered by this License; they are outside its scope.  The act of
running the Program is not restricted, and the output from the Program
is covered only if its contents constitute a work based on the
Program (independent of having been made by running the Program).
Whether that is true depends on what the Program does.

  1. You may copy and distribute verbatim copies of the Program's
source code as you receive it, in any medium, provided that you
conspicuously and appropriately publish on each copy an appropriate
copyright notice and disclaimer of warranty; keep intact all the
notices that refer to this License and to the absence of any warranty;
and give any other recipients of the Program a copy of this License
along with the Program.

You may charge a fee for the physical act of transferring a copy, and
you may at your option offer warranty protection in exchange for a fee.

  2. You may modify your copy or copies of the Program or any portion
of it, thus forming a work based on the Program, and copy and
distribute such modifications or work under the terms of Section 1
above, provided that you also meet all of these conditions:

    a) You must cause the modified files to carry prominent notices
    stating that you changed the files and the date of any change.

    b) You must cause any work that you distribute or publish, that in
    whole or in part contains or is derived from the Program or any
    part thereof, to be licensed as a whole at no charge to all third
    parties under the terms of this License.

    c) If the modified program normally reads commands interactively
    when run, you must cause it, when started running for such
    interactive use in the most ordinary way, to print or display an
    announcement including an appropriate copyright notice and a
    notice that there is no warranty (or else, saying that you provide
    a warranty) and that users may redistribute the program under
    these conditions, and telling the user how to view a copy of this
    License.  (Exception: if the Program itself is interactive but
    does not normally print such an announcement, your work based on
    the Program is not required to print an announcement.)

These requirements apply to the modified work as a whole.  If
identifiable sections of that work are not derived from the Program,
and can be reasonably considered independent and separate works in
themselves, then this License, and its terms, do not apply to those
sections when you distribute them as separate works.  But when you
distribute the same sections as part of a whole which is a work based
on the Program, the distribution of the whole must be on the terms of
this License, whose permissions for other licensees extend to the
entire whole, and thus to each and every part regardless of who wrote it.

Thus, it is not the intent of this section to claim rights or contest
your rights to work written entirely by you; rather, the intent is to
exercise the right to control the distribution of derivative or
collective works based on the Program.

In addition, mere aggregation of another work not based on the Program
with the Program (or with a work based on the Program) on a volume of
a storage or distribution medium does not bring the other work under
the scope of this License.

  3. You may copy and distribute the Program (or a work based on it,
under Section 2) in object code or executable form under the terms of
Sections 1 and 2 above provided that you also do one of the following:

    a) Accompany it with the complete corresponding machine-readable
    source code, which must be distributed under the terms of Sections
    1 and 2 above on a medium customarily used for software interchange; or,

    b) Accompany it with a written offer, valid for at least three
    years, to give any third party, for a charge no more than your
    cost of physically performing source distribution, a complete
    machine-readable copy of the corresponding source code, to be
    distributed under the terms of Sections 1 and 2 above on a medium
    customarily used for software interchange; or,

    c) Accompany it with the information you received as to the offer
    to distribute corresponding source code.  (This alternative is
    allowed only for noncommercial distribution and only if you
    received the program in object code or executable form with such
    an offer, in accord with Subsection b above.)

The source code for a work means the preferred form of the work for
making modifications to it.  For an executable work, complete source
code means all the source code for all modules it contains, plus any
associated interface definition files, plus the scripts used to
control compilation and installation of the executable.  However, as a
special exception, the source code distributed need not include
anything that is normally distributed (in either source or binary
form) with the major components (compiler, kernel, and so on) of the
operating system on which the executable runs, unless that component
itself accompanies the executable.

If distribution of executable or object code is made by offering
access to copy from a designated place, then offering equivalent
access to copy the source code from the same place counts as
distribution of the source code, even though third parties are not
compelled to copy the source along with the object code.

  4. You may not copy, modify, sublicense, or distribute the Program
except as expressly provided under this License.  Any attempt
otherwise to copy, modify, sublicense or distribute the Program is
void, and will automatically terminate your rights under this License.
However, parties who have received copies, or rights, from you under
this License will not have their licenses terminated so long as such
parties remain in full compliance.

  5. You are not required to accept this License, since you have not
signed it.  However, nothing else grants you permission to modify or
distribute the Program or its derivative works.  These actions are
prohibited by law if you do not accept this License.  Therefore, by
modifying or distributing the Program (or any work based on the
Program), you indicate your acceptance of this License to do so, and
all its terms and conditions for copying, distributing or modifying
the Program or works based on it.

  6. Each time you redistribute the Program (or any work based on the
Program), the recipient automatically receives a license from the
original licensor to copy, distribute or modify the Program subject to
these terms and conditions.  You may not impose any further
restrictions on the recipients' exercise of the rights granted herein.
You are not responsible for enforcing compliance by third parties to
this License.

  7. If, as a consequence of a court judgment or allegation of patent
infringement or for any other reason (not limited to patent issues),
conditions are imposed on you (whether by court order, agreement or
otherwise) that contradict the conditions of this License, they do not
excuse you from the conditions of this License.  If you cannot
distribute so as to satisfy simultaneously your obligations under this
License and any other pertinent obligations, then as a consequence you
may not distribute the Program at all.  For example, if a patent
license would not permit royalty-free redistribution of the Program by
all those who receive copies directly or indirectly through you, then
the only way you could satisfy both it and this License would be to
refrain entirely from distribution of the Program.

If any portion of this section is held invalid or unenforceable under
any particular circumstance, the balance of the section is intended to
apply and the section as a whole is intended to apply in other
circumstances.

It is not the purpose of this section to induce you to infringe any
patents or other property right claims or to contest validity of any
such claims; this section has the sole purpose of protecting the
integrity of the free software distribution system, which is
implemented by public license practices.  Many people have made
generous contributions to the wide range of software distributed
through that system in reliance on consistent application of that
system; it is up to the author/donor to decide if he or she is willing
to distribute software through any other system and a licensee cannot
impose that choice.

This section is intended to make thoroughly clear what is believed to
be a consequence of the rest of this License.

  8. If the distribution and/or use of the Program is restricted in
certain countries either by patents or by copyrighted interfaces, the
original copyright holder who places the Program under this License
may add an explicit geographical distribution limitation excluding
those countries, so that distribution is permitted only in or among
countries not thus excluded.  In such case, this License incorporates
the limitation as if written in the body of this License.

  9. The Free Software Foundation may publish revised and/or new versions
of the General Public License from time to time.  Such new versions will
be similar in spirit to the present version, but may differ in detail to
address new problems or concerns.

Each version is given a distinguishing version number.  If the Program
specifies a version number of this License which applies to it and "any
later version", you have the option of following the terms and conditions
either of that version or of any later version published by the Free
Software Foundation.  If the Program does not specify a version number of
this License, you may choose any version ever published by the Free Software
Foundation.

  10. If you wish to incorporate parts of the Program into other free
programs whose distribution conditions are different, write to the author
to ask for permission.  For software which is copyrighted by the Free
Software Foundation, write to the Free Software Foundation; we sometimes
make exceptions for this.  Our decision will be guided by the two goals
of preserving the free status of all derivatives of our free software and
of promoting the sharing and reuse of software generally.

                            NO WARRANTY

  11. BECAUSE THE PROGRAM IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW.  EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED
OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.  THE ENTIRE RISK AS
TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU.  SHOULD THE
PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING,
REPAIR OR CORRECTION.

  12. IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES,
INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING
OUT OF THE USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED
TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY
YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER
PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGES.

                     END OF TERMS AND CONDITIONS

            How to Apply These Terms to Your New Programs

  If you develop a new program, and you want it to be of the greatest
possible use to the public, the best way to achieve this is to make it
free software which everyone can redistribute and change under these terms.

  To do so, attach the following notices to the program.  It is safest
to attach them to the start of each source file to most effectively
convey the exclusion of warranty; and each file should have at least
the "copyright" line and a pointer to where the full notice is found.

    <one line to give the program's name and a brief idea of what it does.>
    Copyright (C) <year>  <name of author>

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program; if not, see <https://www.gnu.org/licenses/>.

Also add information on how to contact you by electronic and paper mail.

If the program is interactive, make it output a short notice like this
when it starts in an interactive mode:

    Gnomovision version 69, Copyright (C) year name of author
    Gnomovision comes with ABSOLUTELY NO WARRANTY; for details type `show w'.
    This is free software, and you are welcome to redistribute it
    under certain conditions; type `show c' for details.

The hypothetical commands `show w' and `show c' should show the appropriate
parts of the General Public License.  Of course, the commands you use may
be called something other than `show w' and `show c'; they could even be
mouse-clicks or menu items--whatever suits your program.

You should also get your employer (if you work as a programmer) or your
school, if any, to sign a "copyright disclaimer" for the program, if
necessary.  Here is a sample; alter the names:

  Yoyodyne, Inc., hereby disclaims all copyright interest in the program
  `Gnomovision' (which makes passes at compilers) written by James Hacker.

  <signature of Moe Ghoul>, 1 April 1989
  Moe Ghoul, President of Vice

This General Public License does not permit incorporating your program into
proprietary programs.  If your program is a subroutine library, you may
consider it more useful to permit linking proprietary applications with the
library.  If this is what you want to do, use the GNU Lesser General
Public License instead of this License.
```

---

## Website assets (not part of the application bundle)

The marketing site under `website/` self-hosts its typefaces rather than loading them
from a third-party CDN. These files ship with the site, not with the app.

| Component | Subsets | License | Where it lives |
|---|---|---|---|
| [Inter](https://github.com/rsms/inter) | Latin, Latin-Ext | SIL OFL 1.1 | `website/assets/fonts/inter-*.woff2` |
| [IBM Plex Mono](https://github.com/IBM/plex) | Latin, Latin-Ext | SIL OFL 1.1 | `website/assets/fonts/ibm-plex-mono-*.woff2` |

Both are unmodified subsets as served by the Google Fonts API. The full license text and
the required copyright notices — *Copyright 2020 The Inter Project Authors* and
*Copyright © 2017 IBM Corp. with Reserved Font Name "Plex"* — are bundled alongside the
font files in [`website/assets/fonts/OFL.txt`](website/assets/fonts/OFL.txt), as OFL 1.1
requires.
