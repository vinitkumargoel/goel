# Support and service levels — Goel° Download Manager

**Document version:** 1.0
**Last updated:** 2026-07-25
**Vendor:** Vinit Kumar Goel
**Contact:** licensing@vinitk.dev

This document states what support each licence tier includes. It is written to be attached
to a purchase order and to be read by someone who has to justify the line item.

Commitments here are **response** commitments — the time to a substantive human reply from
a person who can act on the issue. Resolution time depends on the defect; nobody can
honestly promise a fixed one, and this document does not pretend to.

---

## 1. At a glance

| | **Personal** (free) | **Business** | **Enterprise** |
|---|---|---|---|
| Channel | GitHub issues | Email | Named contact, email + scheduled call |
| Coverage hours | — | Mon–Fri, 09:00–18:00 CET | Mon–Fri, 09:00–18:00 CET |
| First response — Critical | Best effort | 1 business day | **4 business hours** |
| First response — High | Best effort | 2 business days | 1 business day |
| First response — Normal | Best effort | 2 business days | 1 business day |
| First response — Low / question | Best effort | 3 business days | 2 business days |
| Escalation path | — | — | **Yes, documented** |
| Security-release notification | Public release notes | Direct email | Direct email + pre-disclosure |
| Security questionnaire turnaround | Published answers | Published answers | **5 business days**, custom form |
| Licensing/commercial questions | 1 business day | 1 business day | 1 business day |
| Update entitlement | Latest public release | 12 months from purchase | Term of licence |
| Deployment assistance | — | Email guidance | Onboarding session |

"Business day" and "business hours" mean Monday to Friday, 09:00–18:00 Central European
Time, excluding public holidays in the vendor's jurisdiction. Holiday dates are published
in advance to Enterprise licensees.

---

## 2. Severity definitions

Severity is about **impact on you**, not about how hard the fix is. If we disagree with
your assessment we will say so and explain why, rather than silently downgrading it.

| Severity | Definition | Examples |
|---|---|---|
| **Critical** | Production use is stopped, data is at risk, or there is a security vulnerability | App will not launch after an update; downloads corrupt on completion; credential exposure; remotely exploitable defect |
| **High** | A major feature is unusable, with no reasonable workaround | SFTP transfers fail against your server; the web portal will not authenticate; torrents never start |
| **Normal** | A feature misbehaves, but there is a workaround | A column sorts wrongly; a speed limit is not applied in one scheduler window |
| **Low** | Cosmetic issue, documentation error, or a question | Label truncation; a docs clarification; "how do I do X?" |

---

## 3. Personal (free) support

Free use is supported by the community and by the developer's discretion.

- **Channel:** [GitHub issues](https://github.com/vinitkumargoel/goel/issues), public.
- **Commitment:** none. Issues are read and most get a reply, but no timeframe is promised
  and none should be relied upon.
- **Security reports** are the exception: a private security report is acknowledged within
  one business day regardless of licence tier, because that is the right thing to do.
- **Licensing questions** are also answered within one business day, licence or not — if
  you are trying to work out whether you need to pay, you should not have to wait.

---

## 4. Business support

Included with every Business seat licence.

**Channel.** Email to the support address issued with your licence. Reply from a real
person; no ticket-deflection bot, no chatbot triage.

**Response commitment.** Two business days for the first substantive reply (one business
day for Critical). If it needs investigation you get a real update, not an
acknowledgement-only auto-reply.

**What is included:**

- Defect investigation and fixes in supported releases.
- Configuration and deployment guidance — install, MDM packaging questions, protocol
  configuration, web-portal setup.
- Direct email notification when a security release ships, so you are not relying on
  spotting a changelog entry.
- 12 months of updates from purchase. When that lapses, everything you have keeps running
  indefinitely; you just stop receiving new versions until you renew.
- Access to the published compliance pack: [`sbom.md`](sbom.md),
  [`security-questionnaire.md`](security-questionnaire.md), and this document.

**What is not included:**

- Custom development or bespoke features.
- Support for builds you have modified.
- Support for releases more than two minor versions behind current.
- Guaranteed weekend or out-of-hours response.
- Completion of a custom security questionnaire (the published answers cover the standard
  set; a custom form is an Enterprise entitlement).

---

## 5. Enterprise support

Included with an Enterprise site licence.

**Named contact.** You get a named individual and a direct address, not a shared queue.
They know your deployment: platform, scale, protocols in use, and any constraints from
your environment.

**Response commitment.** One business day for the first substantive reply; **four business
hours** for Critical. Critical issues raised during coverage hours get worked continuously
until there is a fix or a documented mitigation.

**Onboarding.** A scheduled session at the start of the licence covering deployment,
configuration, MDM packaging and the security review, so the first month does not turn
into a slow email thread.

**Everything in Business, plus:**

- Custom security questionnaire, vendor-risk assessment or CAIQ/SIG form completed within
  **five business days**.
- Pre-disclosure of security issues affecting your deployment, ahead of public release.
- MDM configuration profile (Jamf / Intune) for fleet deployment.
- Audit logging build options.
- SSO for the web portal.
- VPAT / accessibility conformance report.
- Support for your penetration test or security assessment.
- Roadmap input — a direct line on what gets built next.
- Source-escrow arrangement, if your risk process requires one (written into the
  agreement).

---

## 6. Escalation path (Enterprise)

If a Critical issue is not progressing, escalate. This exists so you never have to guess
whether pushing harder is appropriate — it is, and here is how.

| Level | When | Who | Target |
|---|---|---|---|
| **L1** | Issue raised | Named contact | Per §1 |
| **L2** | No substantive response within the committed time, **or** a Critical issue is unresolved after 2 business days | Escalate by replying to the thread with `ESCALATION` in the subject | Direct developer engagement within 4 business hours |
| **L3** | Critical unresolved after 5 business days | Request a scheduled call | Call within 1 business day, with a written remediation plan and dates |

Escalation contact details are issued with the licence. Escalating is not held against
you; an escalation that turns out to be unnecessary is treated as a signal that the
communication was not clear enough.

---

## 7. Security issues — all tiers

Security reports are handled outside the normal tiers because severity does not depend on
what you paid.

**Report privately** to **licensing@vinitk.dev** with `SECURITY` in the subject. Please do
not open a public issue for an unpatched vulnerability.

| Stage | Target |
|---|---|
| Acknowledgement | 1 business day, all tiers |
| Triage and severity assessment | 3 business days |
| Fix or documented mitigation — Critical | 5 business days |
| Fix or documented mitigation — High | 15 business days |
| Fix or documented mitigation — Medium | 30 business days |
| Coordinated public disclosure | After a fix ships, or 90 days, whichever is sooner |

Reporters are credited publicly with their consent. There is no paid bounty programme.

**Breach notification.** If an incident occurs that could affect a licensee, Business and
Enterprise licensees are notified directly within **72 hours** of confirmation. Note from
[`security-questionnaire.md`](security-questionnaire.md) §8.3 that the vendor holds no
customer product data, so the realistic incident classes are compromise of the signing
key, the update channel, or the source repository.

---

## 8. Supported versions

| Release | Status |
|---|---|
| Current | Fully supported |
| Previous minor | Supported; security fixes and Critical defects |
| Older than two minor versions | Best effort; you may be asked to upgrade first |

Supported platforms: macOS 14 (Sonoma) and later on Apple Silicon; `GoelDaemon` on Linux
distributions carrying a Swift 6.3 toolchain (Ubuntu is the tested path).

---

## 9. What we ask from you

Response commitments assume a report we can act on. To make the first reply useful rather
than a request for more information, include:

- Goel° version, OS version, and whether the build came from Releases or from source.
- What you did, what you expected, what happened.
- The exact error text from the task detail pane.
- Severity, in your assessment, and what it is blocking.
- For portal issues: the HTTP status code and whether a token or a session cookie was used.

Please do not include credentials, tokens or full private URLs. We will never ask for a
password, a Keychain item or an API token — if something appears to, treat it as a
phishing attempt and report it.

---

## 10. Exclusions

Support does not cover:

- Modified builds, or builds from a fork.
- Defects caused by unsupported third-party software or hardware.
- Problems in the remote servers, trackers or peers you are transferring from.
- Network problems outside the application.
- Use in breach of the licence (running unlicensed in an organisation) — though a
  licensing conversation is always welcome and is never treated as a support matter.

---

## 11. Changes to this document

Service levels may be revised for future licence terms. **The levels in force for your
licence are those published when it was purchased or last renewed**, and material
reductions are notified to affected licensees before renewal. Revisions are versioned at
the top of this file.
