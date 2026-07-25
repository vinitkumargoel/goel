# Security Policy — Goel°

Goel° speaks TLS to arbitrary servers, joins BitTorrent swarms, authenticates over SSH,
and can expose a local HTTP control server on your network. Security reports are taken
seriously and answered by a human.

---

## Reporting a vulnerability

**Do not open a public GitHub issue for a security problem.**

- **Email:** security@vinitk.dev
- **PGP key:** `TODO(owner)` — publish a fingerprint here, or state plainly that plain
  email is acceptable. Do not leave it ambiguous; a reporter who cannot tell will either
  send it in the clear anyway or give up.
- **GitHub Private Vulnerability Reporting** is also enabled on
  [the repository](https://github.com/vinitkumargoel/goel/security/advisories/new), if
  you prefer it to email.

Please include:

1. Affected version (**Goel° → About**, or `git rev-parse HEAD` for a source build) and
   your macOS or Linux version.
2. What an attacker gains, and what they need in order to get it — network position,
   local access, a malicious server, a crafted torrent, a user click.
3. Reproduction steps, ideally minimal. A crafted file, a URL, or a short script is worth
   more than a paragraph of description.
4. Whether the issue is already public, and any disclosure deadline you are working to.

You will not be threatened, sued, or told off for reporting in good faith. Testing
against your own machines and your own servers is fine. Testing against other people's
infrastructure is not, and is not covered by anything here.

---

## Response commitment

| Stage | Commitment |
|---|---|
| **Acknowledgement** | Within **2 business days**. If you have not heard back in that time, assume the mail was lost and send it again. |
| **Triage and initial assessment** | Within **5 business days** — severity, whether it is confirmed, and an expected fix window. |
| **Fix for critical or high severity** | Patched release within **7 calendar days** of confirmation. |
| **Fix for medium severity** | Next scheduled release, and within 90 days. |
| **Fix for low severity** | Next scheduled release. |
| **Public advisory** | Published at the same time as the fix, or at 90 days from the report, whichever is sooner. |

Goel° is maintained by one person. That is precisely why these numbers are written down:
a commitment you can hold the maintainer to is worth more than a vague promise of prompt
attention. If a deadline is going to slip, you will be told before it slips, not after.

**Credit:** reporters are named in the advisory and in [CHANGELOG.md](CHANGELOG.md) unless
they ask not to be. There is no bug bounty — this is an unfunded project — and that is
stated up front rather than discovered after you have done the work.

---

## Supported versions

| Version | Supported |
|---|---|
| Latest release | Yes |
| Previous minor release | Security fixes only, for 90 days after the newer release |
| Anything older | No |
| Source builds from `main` | Best effort; report anyway, `main` is where fixes land first |

Commercial licensees may have longer support windows written into their agreement; those
terms take precedence over this table for those customers.

---

## Vendored dependency CVE policy

This is the section enterprise reviewers actually ask about, so it is answered directly.

### What is bundled and why it is a risk

Goel° ships as a **self-contained application**. libtorrent, OpenSSL, libssh2, Boost and
(when included) yt-dlp are compiled in or vendored into
`Goel°.app/Contents/Frameworks/` at build time. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full inventory.

That is a deliberate trade: users install nothing, there is no Homebrew requirement, and
the app cannot be broken by an unrelated system upgrade. The cost is equally real and is
not hidden here:

- **Frozen versions.** A bundled library is whatever it was on the day the release was
  built. It does not track upstream.
- **No independent patch path.** `brew upgrade openssl@3` does nothing for the copy
  inside the app bundle. The system's OpenSSL is not the one Goel° uses.
- **Therefore every dependency CVE requires a new Goel° release.** There is no other
  mechanism, by design.

### The commitments

1. **Quarterly review.** Every bundled dependency is checked against upstream advisories
   and the NVD at least **once per calendar quarter** (January, April, July, October).
   The review covers libtorrent-rasterbar, OpenSSL, libssh2, Boost, GRDB, Sparkle, and
   yt-dlp. The outcome — including "reviewed, nothing applicable" — is recorded in
   [CHANGELOG.md](CHANGELOG.md) so the cadence is externally verifiable rather than
   something you have to take on trust.

2. **Seven-day critical window.** When a **critical or high severity** CVE is published
   against a bundled dependency **and Goel° is affected by it**, a patched release ships
   within **7 calendar days** of the advisory becoming public. The clock starts at public
   disclosure, not at whenever the maintainer noticed.

3. **Medium and low severity** dependency CVEs are folded into the next scheduled
   release, and within 90 days.

4. **Applicability is assessed, and the assessment is published.** A CVE in a code path
   Goel° never reaches is not a reason to ship a rushed build, but it *is* a reason to say
   so publicly. Where a bundled dependency has a live CVE that does not affect Goel°, the
   reasoning is written down in the advisory or the changelog. "Not exploitable in our
   configuration" without an explanation is not an acceptable answer to give a reviewer,
   and it will not be given here.

5. **Versions are auditable.** Swift package dependencies are pinned exactly in
   `Package.resolved` and listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The
   C libraries are sourced at build time, so their exact versions are a property of each
   build and are recorded in the per-release SBOM, available on request. That file also
   explains how to read the versions out of a build you already have. You never have to
   guess what is inside something you have deployed.

6. **Upgrade path.** Sparkle is bundled specifically so that a dependency patch can be
   delivered as a normal in-app update rather than a manual re-download. Fleet deployments
   that disable Sparkle should subscribe to the releases feed and treat a Goel° release as
   the delivery mechanism for a dependency patch.

### Subscribing to notifications

- Watch [Releases](https://github.com/vinitkumargoel/goel/releases) on GitHub.
- Watch [Security Advisories](https://github.com/vinitkumargoel/goel/security/advisories).
- Commercial licensees receive security releases by email — supply a distribution list
  rather than a personal address when you buy.

---

## Security properties worth knowing about

Useful context for anyone reviewing the app, and honest about the limits.

- **No telemetry.** Goel° transmits nothing about you or your use anywhere. There is no
  analytics, no crash upload, no phone-home, and no licence check. Network traffic comes
  from downloads you asked for, update checks, and nothing else. This is a written product
  guarantee, and the code is available so you can verify it rather than believe it.
- **No licence enforcement.** There is no activation server and no key check — so there is
  no such server to compromise and no such credential to steal.
- **Credentials** (SFTP passwords, remote-control tokens, site logins) are stored in the
  macOS Keychain, not in the database or in plaintext configuration.
- **SSH host-key pinning** is enforced for SFTP; a changed host key is surfaced to the
  user rather than silently accepted.
- **The remote-control server binds loopback by default.** Exposing it to the LAN requires
  authentication to be configured first — the daemon refuses to bind a LAN interface
  without a password set.
- **Downloaded files are data, not trust.** Goel° does not execute what it downloads.
  Post-download actions (extract, run script, antivirus scan) run only when the user has
  explicitly configured them, and a user-configured script is a user-configured script —
  it runs with the user's privileges and Goel° cannot make that safe for you.

---

## Out of scope

The following are not treated as vulnerabilities in Goel°:

- Vulnerabilities in a remote server you are downloading from.
- Content-piracy or copyright complaints. Goel° is a transport tool; what you point it at
  is your responsibility and belongs with the site operator, not here.
- Attacks requiring an already-compromised local user account, or physical access to an
  unlocked machine.
- Missing hardening that has no demonstrable exploit path — send the exploit path, not the
  scanner output.
- Reports consisting solely of automated-scanner findings with no analysis.
- Social engineering of the maintainer.
