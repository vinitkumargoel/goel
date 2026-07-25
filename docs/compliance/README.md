# Compliance pack — Goel° Download Manager

Everything an enterprise procurement or security review normally has to request by email,
published up front.

| Document | Answers |
|---|---|
| [sbom.md](sbom.md) | What is in the binary, under which licences, from where, and what obligations that puts on you |
| [security-questionnaire.md](security-questionnaire.md) | ~40 pre-written answers: telemetry, data handling, encryption, credential storage, network egress, dependency policy, patch SLA, incident response, vendor continuity |
| [support-sla.md](support-sla.md) | Business vs Enterprise response commitments, severity definitions, escalation path, supported versions |

## The three answers reviewers ask for first

**Does it transmit anything to the vendor?** No. No analytics, no crash reporting, no
usage counters, no licence check-in. The code to do it does not exist in the product, and
you can confirm that in the public source. In a commercial agreement this is a written
warranty, not a marketing claim.

**Is there copyleft in the shipped binary?** No. BSD-3-Clause, BSL-1.0, Apache-2.0, MIT
and Unlicense only. Nothing obliges you to disclose your own source.

**Is this SaaS?** No. It is a locally-installed application with no vendor-operated
component in the data path. There is no account system, no tenant, and no vendor-held
customer data — which is why most of a standard SaaS questionnaire is not applicable here.
The reasons why are set out explicitly rather than left blank.

## Where these documents are honest about limitations

Stated as limitations on purpose, so you find them here rather than three weeks into a
review: no third-party penetration test to date, no SOC 2 or ISO 27001 certification, the
web portal does not terminate TLS itself, and there is no application-level database
encryption beyond FileVault. Each is discussed in
[security-questionnaire.md](security-questionnaire.md).

## Anything not covered here

A completed CAIQ or SIG, a signed DPA, architecture diagrams, a machine-readable SPDX or
CycloneDX SBOM for a specific release tag, or a call with the developer — email
**licensing@vinitk.dev**. Enterprise licensees get a custom questionnaire completed within
five business days.

See also the [commercial licensing page](https://goel.vinitk.dev/commercial) for the
eligibility table, indicative pricing and the enquiry form.
