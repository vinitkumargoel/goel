# Security questionnaire — Goel° Download Manager

**Document version:** 1.0
**Last updated:** 2026-07-25
**Vendor:** Vinit Kumar Goel
**Product:** Goel° Download Manager (macOS 14+ arm64; headless Linux daemon)
**Contact:** licensing@vinitk.dev

Pre-written answers to the questions enterprise security review asks. Every answer here
is verifiable against the public source at
[github.com/vinitkumargoel/goel](https://github.com/vinitkumargoel/goel).

If your organisation has its own questionnaire form (CAIQ, SIG Lite, VSA, or an internal
one), Enterprise licensees get it completed and returned within five business days — see
[`support-sla.md`](support-sla.md).

---

## 0. The three answers reviewers usually want first

| Question | Answer |
|---|---|
| Does the product transmit any data to the vendor? | **No. None. Ever.** |
| Is customer data processed by the vendor? | **No.** We never receive it, so we cannot process it. |
| Is this a SaaS product? | **No.** It is a locally-installed application with no backend of ours. |

Goel° is not a cloud service. There is no vendor-operated infrastructure in the data path,
no account system, no tenant, and no vendor-held customer data. Most of a standard
security questionnaire is therefore not applicable — the reasons why are set out below
rather than being left blank.

---

## 1. Product architecture

**1.1 What is the deployment model?**
On-premises / on-device only. The application runs on the end user's Mac, or as a headless
daemon (`GoelDaemon`) on a Linux host you control. There is no vendor-hosted component.

**1.2 What is the technology stack?**
Swift 6 (strict concurrency) with a SwiftUI front end on macOS. Persistence is SQLite via
GRDB. Native libraries: libtorrent-rasterbar (BitTorrent), libssh2 (SFTP), libcurl
(HTTP/FTP), OpenSSL 3 (TLS and crypto). Full component list in [`sbom.md`](sbom.md).

**1.3 Does the product require internet access to function?**
No. It requires network access to whatever you are downloading from. It does not require
any connection to the vendor, and it will run fully air-gapped with the update check
disabled.

**1.4 Does the product require administrator privileges?**
No. It installs and runs as a normal user application. It does not install a kernel
extension, a system extension, or a privileged helper daemon.

**1.5 Is there a server-side/multi-tenant component?**
No.

---

## 2. Telemetry, analytics and data collection

**2.1 Does the product collect telemetry?**
**No.** There is no analytics SDK, no usage counter, no metrics beacon, no session
recording, no A/B framework and no advertising identifier. This is not a default that can
drift — the code to do it does not exist in the product, and its absence is contractually
warranted in commercial agreements.

**2.2 Does the product collect crash reports?**
No automatic crash uploading. A user may choose to attach diagnostic output to a support
request; that is an explicit, user-initiated act.

**2.3 Does the product "phone home" for licensing?**
No. There is no licence key, no activation call, no entitlement check and no heartbeat.
Licensing is contractual and honour-based; the binary a licensed enterprise runs is
identical to the public one.

**2.4 What personal data does the vendor hold about our users?**
None from the product. The only data we ever hold is what someone deliberately sends us —
a licensing enquiry or a support email — used solely to answer it.

**2.5 Are there third-party trackers in the app or on the website?**
None in the app. The marketing website has no analytics and no cookies; it loads
typefaces from Google Fonts, which means Google's servers see the font request (IP and
user agent). The licensing enquiry form posts to a Cloudflare Worker operated by the
vendor and is forwarded to one mailbox — it is not stored in a database or a CRM.

**2.6 GDPR / CCPA role?**
For product use, the vendor is **not** a processor or controller of your data: no data
flows to us. For a licensing or support enquiry, the vendor is the controller of the
contact details you chose to send. There is no data-processing agreement to sign for
product use because there is no processing; one can be executed for the enquiry data if
your policy requires it.

---

## 3. Data handling and storage

**3.1 Where is application data stored?**
Locally on the user's device: queue state and download history in a SQLite database in the
app support directory, downloaded files wherever the user chose, credentials in the macOS
Keychain.

**3.2 Is data encrypted at rest?**
The application relies on the platform: FileVault on macOS, and full-disk or filesystem
encryption on Linux hosts. Credentials are additionally protected by the Keychain, which
is encrypted independently of FileVault. The application does not add its own database
encryption layer — if your policy requires encrypted-at-rest application databases beyond
FileVault, raise it during the Enterprise scoping conversation.

**3.3 Is data encrypted in transit?**
Yes, wherever the protocol supports it: HTTPS, FTPS (explicit and implicit TLS), SFTP over
SSH, and HLS over HTTPS including AES-128-CBC encrypted segments. Where a user explicitly
chooses a plaintext protocol (plain HTTP, plain FTP), the traffic is plaintext by that
choice.

**3.4 Which TLS versions are used?**
OpenSSL 3.x with SSL2, SSL3, TLS 1.0, TLS 1.1 and DTLS 1.0 compiled out of the libtorrent
build. macOS system libraries (libcurl, Security.framework) follow the OS TLS policy.

**3.5 What is the data retention policy?**
Entirely under your control — history retention is a user setting and can be cleared at
any time. The vendor retains nothing, so there is nothing on our side to expire.

**3.6 How is data exported or deleted?**
Backups export as plain JSON files the user creates and holds. History entries are
deletable individually or in bulk. Uninstalling removes the app; downloaded files are
ordinary files and remain.

---

## 4. Credentials, authentication and secrets

**4.1 How are user credentials stored?**
Site logins, FTP/SFTP passwords and SSH key passphrases are stored in the **macOS
Keychain**, never in plaintext configuration. The application requests them from the
Keychain at the point of use. A Keychain refusal is surfaced as an explicit error rather
than being silently swallowed.

**4.2 How is the web portal password stored?**
As a salted, iterated digest only — never recoverably. Format `v2$saltHex$hashHex`:
**PBKDF2-HMAC-SHA256, 210,000 iterations, 16-byte cryptographically random salt**. A
legacy `v1` format (iterated SHA-256) is still verified so existing installs upgrade
cleanly. A leaked settings file does not disclose the password.

**4.3 How does the remote API authenticate?**
Three accepted paths: a session cookie (`goel_session`; `HttpOnly`, `SameSite=Strict`,
32 random bytes, expiring), a bearer token (`Authorization: Bearer …`), or a `?token=`
query parameter for scripts. Token and username comparisons are **constant-time**, so
response timing cannot be used to recover them byte by byte.

**4.4 Is there brute-force protection?**
Yes, applied **per client address with exponential backoff**. Both parameters are
settings; the shipped defaults are five free attempts, then a five-second lockout that
**doubles on every further failure** up to a fifteen-minute ceiling. A correct password
clears that address's record immediately, and an address that goes quiet is forgotten
after an hour so a shared NAT egress IP does not accumulate penalties forever. The
lockout is checked *before* the password is verified, so a flood costs the attacker a
dictionary lookup rather than a PBKDF2 run. There is also a cap on concurrent password
verifications returning `429`, which prevents the deliberately expensive PBKDF2 work from
being used as a CPU-exhaustion vector.

The key is the real TCP peer address, never a client-supplied header, so one guessing
attacker cannot lock the legitimate user out. The corollary is stated plainly: a
distributed attacker gets one attempt budget per source address, so this throttle bounds
one host's guessing rate, not a botnet's. That is a reason to put the portal behind a
proxy, VPN or Tailscale rather than on the open internet — see 5.4.

**4.5 Is SSO supported?**
SSO for the web portal is an Enterprise entitlement. The core application has no accounts
at all, so there is nothing to federate on the desktop side.

**4.6 Does the vendor hold any customer secrets?**
No. We have no access to any credential, key or token used by the product.

---

## 5. Network exposure

**5.1 What outbound connections does the product make?**

| Connection | Trigger | Disableable |
|---|---|---|
| The transfers themselves | User adds a download | Inherent to the product |
| BitTorrent peer/tracker/DHT traffic | User adds a torrent | Don't use torrents |
| Update check (Sparkle / GitHub Releases) | Periodic, macOS | **Yes** — Settings → Updates |

There is no fourth category. Nothing is proxied through vendor infrastructure.

**5.2 What inbound listeners does the product open?**
Two, both optional:
- **BitTorrent peer port** — only while torrenting.
- **The web portal (Goel° Web)** — only when the user enables it. Default guidance is to
  bind to loopback.

**5.3 Is the web portal hardened?**
Yes. Every response carries `Content-Security-Policy: default-src 'none'` (with
same-origin `connect-src`, `img-src 'self' data:`, `media-src 'self'`, `form-action
'self'`, `base-uri 'none'`), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer` and `Cache-Control: no-store`. Concurrent connections are
capped at 32 and live event streams at 4.

**5.4 Does the portal do TLS?**
No — it does not terminate TLS itself. Deploy it behind a reverse proxy, a VPN or
Tailscale if it must be reachable beyond loopback. This is documented rather than
implied.

**5.5 Is there a read-only mode?**
Yes. When enabled, every mutating route returns `403` before routing. Because all
mutations in the API are POSTs, read-only genuinely means read-only.

**5.6 What prevents a remote client writing files anywhere on disk?**
The remote "add download" route accepts a save folder, and a folder outside the configured
downloads root is **rejected**, falling back to the safe default. Without this an
authenticated remote client could drop a file into an auto-run location such as
`~/Library/LaunchAgents` or `/etc/cron.d`. The rejection is logged.

---

## 6. Application security

**6.1 Is the application code-signed?**
Yes. macOS releases are signed with a Developer ID and notarised by Apple. Local
development builds are signed with a stable identity so macOS retains permission grants
across rebuilds.

**6.2 How is update integrity ensured?**
Sparkle verifies an EdDSA signature on the update before installing it, over HTTPS. An
unsigned or mis-signed update is refused. The whole mechanism can be disabled.

**6.3 Does the app run sandboxed?**
It is distributed outside the Mac App Store and requires access to user-chosen download
locations and network hosts. Hardened Runtime is enabled for notarisation. It does not
install kernel extensions or privileged helpers.

**6.4 What memory-safety posture does the code have?**
The application and engine are Swift, which is memory-safe by default, built with Swift 6
strict concurrency (actor isolation enforced at compile time, eliminating data races in
the engine). The unsafe surface is confined to thin C/C++ bridge targets
(`TorrentBridge`, `CurlBridge`, `SSHBridge`, `CryptoBridge`) that wrap the native
libraries.

**6.5 Is there a test suite?**
Yes — 418 tests covering the engine, model, persistence, scheduler and the remote router,
including its authentication and authorisation logic. The router is a pure function of the
request, so auth behaviour is unit-tested without a socket.

**6.6 Has a third-party penetration test been performed?**
Not to date. The source is public and open to your own review, and an Enterprise agreement
can include supporting your penetration test or security assessment.

**6.7 Is there input validation on the remote API?**
Yes. Malformed or missing identifiers return `400`, unknown tasks `404`, and the add
endpoint refuses a request in which no source line parses. Field values are bounded and
save paths are containment-checked.

---

## 7. Dependency and patch management

**7.1 What is the dependency policy?**
Dependencies are deliberately few and all permissively licensed. Swift packages are
version-pinned in `Package.resolved` with exact git revisions, so builds are reproducible.
No dependency is added without a specific need; there is no transitive sprawl of
analytics, ad or tracking SDKs — the product has none of those categories at all.

**7.2 Is there any copyleft code in the shipped binary?**
No. BSD-3-Clause, BSL-1.0, Apache-2.0, MIT and Unlicense only. See [`sbom.md`](sbom.md).

**7.3 How are vulnerable dependencies detected?**
Upstream advisories are monitored for the bundled native libraries (OpenSSL, libssh2,
libtorrent-rasterbar, Boost) and for the Swift packages. GitHub security advisories are
enabled on the repository.

**7.4 What is the patch SLA?**

| Severity | Fix or documented mitigation | Release |
|---|---|---|
| Critical (remote code execution, credential disclosure) | 5 business days | Immediately on fix |
| High | 15 business days | Next release, expedited |
| Medium | 30 business days | Next scheduled release |
| Low | Best effort | Next scheduled release |

A vulnerability in a bundled third-party library is treated at the severity of its effect
on Goel°, and is fixed by rebuilding against the patched library.

**7.5 How are licensees notified of a security release?**
Business and Enterprise licensees are emailed directly — you should not have to watch a
changelog to learn you need to patch. Enterprise licensees receive pre-disclosure where
the issue affects their deployment. Personal users see it in the public release notes.

---

## 8. Vulnerability disclosure and incident response

**8.1 How do we report a vulnerability?**
Privately, to **licensing@vinitk.dev** with `SECURITY` in the subject. Please do not open a
public issue for an unpatched vulnerability.

**8.2 What is the response process?**

| Stage | Target |
|---|---|
| Acknowledgement of report | 1 business day |
| Initial triage and severity assessment | 3 business days |
| Fix or documented mitigation plan | 5 business days (critical), per §7.4 otherwise |
| Coordinated public disclosure | After a fix ships, or 90 days, whichever is sooner |

**8.3 What is the incident response process for a vendor-side incident?**
The vendor holds no customer product data, so the realistic incident classes are narrow:
compromise of the code-signing key, of the update channel, or of the source repository.
The response is to revoke and re-issue signing material, halt the update feed, notify
licensed customers directly within 72 hours of confirmation, and publish the details.

**8.4 Is there a bug bounty?**
No paid bounty programme. Reports are credited publicly with the reporter's consent.

**8.5 Are we notified of a breach?**
Yes — Business and Enterprise licensees are notified directly within 72 hours of
confirming an incident that could affect them.

---

## 9. Vendor and business continuity

**9.1 What is the vendor's size and structure?**
An independent single-developer vendor. This is stated plainly because it is the right
input to your risk assessment: the response times in [`support-sla.md`](support-sla.md)
are committed with that in mind, not in spite of it.

**9.2 What happens if the vendor ceases operations?**
The source is public and remains available. A Business licence is perpetual — deployed
software keeps working indefinitely. An Enterprise licence runs to its term. Source-escrow
arrangements can be written into an Enterprise agreement.

**9.3 Are subcontractors or offshore staff involved?**
No subcontractors have access to source, signing keys or customer data.

**9.4 What vendor infrastructure exists?**
GitHub (source, releases, issues) and Cloudflare (marketing site and the licensing enquiry
endpoint). Neither sits in the path of any customer's downloads or data.

**9.5 Do you hold ISO 27001 / SOC 2?**
No. Formal certification is not held. Given that no customer data reaches the vendor, the
scope such an audit would cover is the source and release pipeline; we are happy to
evidence controls over those directly during your review.

---

## 10. Compliance and accessibility

**10.1 Accessibility conformance?**
A VPAT / accessibility conformance report is an Enterprise entitlement. The macOS app is
built in SwiftUI with keyboard navigation and VoiceOver labelling; the web portal marks up
its interactive controls for assistive technology.

**10.2 Export control?**
The product includes and uses standard cryptography (TLS, SSH, AES) from OpenSSL and
platform libraries. It implements no proprietary cryptography. Confirm your own
jurisdiction's obligations before redistributing internationally.

**10.3 Does the product enable users to violate copyright?**
Goel° is a general-purpose transfer client, like a browser or an FTP client. It has no
content index, no search, no catalogue and no bundled sources. What a user downloads is
the user's responsibility, and acceptable-use terms are yours to set.

**10.4 Can we restrict features in a managed deployment?**
An MDM configuration profile (Jamf / Intune) for enforcing settings across a fleet is an
Enterprise entitlement. Note that this restricts configuration; it is not a licence
enforcement mechanism, because there is none.

---

## 11. Questions this document does not answer

If your review needs something not covered here — a completed CAIQ or SIG, a signed DPA, a
custom questionnaire, architecture diagrams, or a call with the developer — email
**licensing@vinitk.dev**. Enterprise licensees get a completed custom questionnaire within
five business days.

We will tell you plainly what exists today and what is roadmap. Where an answer above is a
limitation rather than a strength (no third-party pen test, no SOC 2, no TLS in the portal
itself, no application-level database encryption), it is stated as one on purpose.
