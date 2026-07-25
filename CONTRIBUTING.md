# Contributing to Goel°

Thanks for wanting to help. Goel° is a single-author project, and it stays healthy by
keeping the code consistent and the paperwork boring. This file covers both.

Read the [DCO sign-off](#the-dco-sign-off) and [inbound licence grant](#inbound-licence-grant)
sections before you open your first pull request. They are short, and a PR without a
sign-off cannot be merged — not because of bureaucracy, but for the reason set out below.

---

## The DCO sign-off

Every commit must carry a `Signed-off-by:` trailer:

```
Signed-off-by: Jane Developer <jane@example.com>
```

Git writes it for you with `-s`:

```bash
git commit -s -m "fix(http): retry on a truncated chunked response"
```

Use your real name and a real, reachable email address. Anonymous and pseudonymous
sign-offs do not do the job a sign-off exists to do.

Forgot on the last commit:

```bash
git commit --amend -s --no-edit
```

Forgot across a branch:

```bash
git rebase --signoff main
```

By adding the trailer you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/), reproduced in
full at the bottom of this file.

### Why this matters here specifically

Goel° is **source-available, not OSI open source**. It is licensed under
[PolyForm Noncommercial 1.0.0](LICENSE), and commercial users buy a
[separate commercial licence](LICENSE-COMMERCIAL.md). That is a dual-licensing model, and
dual licensing only works if **one party holds enough rights over the whole codebase to
grant the commercial licence**.

If a contributor's patch lands with no record of who wrote it, whether they had the right
to submit it, or under what terms, then that patch cannot safely be included in anything
sold commercially. In practice this means one of three bad outcomes:

1. The commercial licence quietly covers code the author has no right to sell.
2. The patch has to be ripped out and rewritten from scratch, years later, by someone
   who has to prove they never read it.
3. The commercial offering stalls entirely while provenance is reconstructed from git
   archaeology and old email.

Every one of those is expensive. All of them are avoided by a one-line trailer.

**The project has exactly one author today.** Adding this requirement now costs nothing
and covers everything. Adding it after fifty contributors have landed patches means
chasing fifty people for retroactive permission, and the ones who have moved on, changed
email, or simply do not reply become permanent holes in the codebase. Projects have been
killed by exactly this. Doing it on day one is free; doing it later may be impossible.

### DCO versus CLA — and why this project has a small piece of both

Being precise, because the distinction is often muddled:

- A **DCO** certifies *provenance* — you wrote it, or you had the right to pass it on. It
  does **not**, by itself, give the maintainer any right to relicense your contribution
  under different terms.
- A **CLA** grants the maintainer *rights* — typically a broad licence, sometimes an
  assignment — including the right to sublicense commercially.

A DCO alone would not be enough to support the commercial licence. A full CLA with a
signature workflow is heavy, off-putting, and overkill for a project this size. So Goel°
uses the DCO for provenance plus the short, explicit grant below for rights. Together
they do the job of a CLA without anyone having to print, sign and scan anything.

---

## Inbound licence grant

By submitting a contribution to this project — a pull request, a patch, a code suggestion
in an issue — **and signing off on it under the DCO**, you additionally agree that:

1. You grant Vinit Kumar Goel a perpetual, worldwide, non-exclusive, royalty-free,
   irrevocable licence to use, reproduce, modify, prepare derivative works of, publicly
   display, distribute and **sublicense** your contribution, **under any licence terms,
   including commercial and proprietary terms**.
2. You grant that same set of parties a perpetual, worldwide, non-exclusive, royalty-free,
   irrevocable patent licence covering any patent claims you can license that your
   contribution would otherwise infringe.
3. **You keep your copyright.** This is a licence, not an assignment. You may use your own
   contribution anywhere else, under any terms you like, without asking anyone.
4. You confirm you are legally able to make this grant — that the contribution is yours,
   and that if you wrote it on an employer's time or equipment, your employer permits it.

That is the whole grant. Point 3 is the one people worry about, so it is worth repeating:
your code stays yours. You are giving permission, not ownership.

If your employer's policy requires a signed agreement rather than a trailer in a commit,
contact `TODO(owner): licensing@example.com` before you start work, and we will sort out
the paperwork rather than discover the problem at merge time.

---

## Before you write code

**Open an issue first for anything non-trivial.** A bug fix with a failing test attached
is always welcome unannounced. A new engine, a new settings pane, a new dependency, or a
refactor spanning more than a couple of files should be discussed first — there is a good
chance it is already planned, already rejected for a reason, or about to collide with
work in flight.

Things that will be declined regardless of how well they are written:

- **Anything that transmits user data off the machine.** No telemetry, no analytics, no
  crash uploads, no "anonymous usage statistics", no update pings that carry more than
  they need. "No telemetry" is a written product guarantee and a commercial selling
  point. Diagnostics are local files the user chooses to send, or they do not exist.
- **Any licence enforcement mechanism.** No key checks, no activation, no trial clocks,
  no feature gating, no nag screens. The app behaves identically for every user, paid or
  not. Compliance is honour-based on purpose. Nothing in this codebase may ever be able
  to lock a user out of their own downloads.
- **New third-party dependencies with copyleft or field-of-use restrictions.** Every
  bundled dependency must be permissive (see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md))
  so the whole can be relicensed commercially. A GPL or LGPL dependency is a hard stop
  unless it can be kept at arm's length as a separate process.

---

## Development setup

macOS 14+ with a Swift 6 toolchain. Homebrew is needed **only to build** — the shipped
`.app` is self-contained.

```bash
brew install libtorrent-rasterbar openssl@3 libssh2 boost
swift build
swift test
swift run GoelDownloader
```

Linux daemon builds are covered in the [README](README.md#build-from-source).

---

## Code style

**Match the surrounding code.** That instruction does more work than a style guide would,
because this codebase is internally consistent and the conventions are visible in any file
you open.

Specifically:

- **Doc comments explain *why*, not *what*.** `/// Increments the counter` is noise.
  `/// Kept separate from the main queue so a stalled SFTP handshake cannot starve HTTP
  transfers` is the standard here. If a decision looks arbitrary, write down why it is not.
- **Swift 6 strict concurrency is enforced.** Respect actor isolation, mark types
  `Sendable` deliberately rather than by reflex, and do not reach for `@unchecked Sendable`
  or `nonisolated(unsafe)` to silence a warning you have not understood.
- **Keep access control tight.** Default to `internal`; make things `public` only when a
  different module genuinely needs them.
- **Follow the existing naming.** Types, services, engines and views all have established
  patterns — read a neighbour before inventing one.

---

## Tests

The suite runs in about 13 seconds. There is no excuse for skipping it.

```bash
swift test
```

- **Bug fixes need a regression test** that fails before the fix and passes after.
- **New behaviour needs tests** covering the failure paths, not only the happy path.
- **Do not weaken or delete an existing test** to make a change pass. If a test is wrong,
  say so explicitly in the PR and explain why.
- Tests must not require network access, a real server, or credentials.

---

## Commits and pull requests

- **Conventional Commits** for subjects: `fix(sftp): …`, `feat(http): …`, `refactor: …`,
  `chore(build): …`. The existing history is the reference.
- Write the body to explain **why**, when the why is not obvious from the diff.
- **One logical change per PR.** A drive-by reformat buried in a bug fix makes the fix
  unreviewable.
- Every commit signed off (see above).
- Note any user-visible change so it can go in [CHANGELOG.md](CHANGELOG.md).

---

## Security issues

**Do not open a public issue for a vulnerability.** Follow [SECURITY.md](SECURITY.md).

---

## Developer Certificate of Origin 1.1

Reproduced verbatim from <https://developercertificate.org/>.

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```
