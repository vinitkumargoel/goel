# Commercial Licence — Goel°

Goel° is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).
That licence is generous for individuals and free forever for personal use, but it grants
**no rights at all for commercial purposes**. If your use is commercial, you need a
separate, paid commercial licence from the author.

This document explains who needs one, how to get one, and what you get for the money.

> **Placeholder notice for the maintainer:** every address, price band and legal-entity
> detail marked `TODO(owner)` below is a placeholder. Fill them in before publishing this
> file or linking to it from the website. Nothing here is a binding offer until you do.

---

## Who needs a commercial licence

You need one if **any** of the following is true:

- You are a **company, partnership, sole trader or other for-profit entity**, and Goel°
  is used in the course of that business — including by a single employee on a single
  laptop, and including internal-only, back-office or IT-support use.
- You are a **contractor or consultant** using Goel° in work you bill to a client.
- You are a **government body, agency, department or public authority** and your use is
  outside what PolyForm's *Noncommercial Organizations* clause covers, or your
  procurement process requires a named, invoiced supplier agreement. (Many public bodies
  are permitted under PolyForm itself — see below — but still need paperwork.)
- You **deploy Goel° to a managed fleet** — MDM, Jamf, Intune, Munki, a golden image, a
  Docker image, or `GoelDaemon` running on shared or company-owned infrastructure.
- You **bundle, resell, host, or offer Goel° as part of a product or service** to third
  parties, including as a managed or hosted download service.
- You need the software under terms the PolyForm licence does not offer — a warranty, an
  indemnity, a support commitment, or a signed agreement your legal team can file.

## Who does **not** need one

You do not need to buy anything if you are:

- An **individual using Goel° for personal purposes** — your own downloads, hobby
  projects, private study, home media, amateur pursuits.
- A **student or researcher** whose use has no anticipated commercial application.
- A **charity, school, university, public research body, public safety or health
  organisation, or environmental protection organisation** — PolyForm's *Noncommercial
  Organizations* clause already permits your use, regardless of how you are funded.
- **Evaluating** Goel° to decide whether to buy a commercial licence. Evaluation is
  explicitly welcome and is not metered, time-limited, or reported anywhere.

If you are unsure which side of the line you fall on, ask. A one-line email costs you
nothing and the answer is usually "you're fine".

---

## What the software does *not* do

Worth stating plainly, because it is unusual and it is a deliberate product decision:

- There is **no licence key**, no activation, no serial number, no online check.
- There is **no trial clock** and nothing expires.
- There is **no feature gating** — the paid licence unlocks nothing, because nothing is
  locked. Every user runs the identical binary with the identical capabilities.
- There is **no telemetry, no analytics, and no phone-home**. Nothing about your use is
  transmitted anywhere, and nothing checks whether you have paid.

Compliance is **honour-based**. The commercial licence is a legal instrument, not a
technical one. We would rather trust you and be occasionally wrong than ship software
that can lock a paying customer out of their own downloads at the worst possible moment.

---

## How to request a licence

Email the address below with the following, and you will get a quote back.

- **Licensing enquiries:** licensing@vinitk.dev
- **Website:** <https://goel.vinitk.dev/commercial> — pricing, the full entitlement matrix,
  and an enquiry form if you would rather not email.

Include:

1. **Legal entity name** and registered address (this is what goes on the licence and
   the invoice).
2. **Seat count** — how many people, or how many machines, will use Goel°. If you are
   deploying `GoelDaemon` to servers, say how many hosts.
3. **Term** — annual or perpetual (see below).
4. **VAT / GST / tax registration number**, if you have one.
5. **Anything your procurement process needs from us** — a security questionnaire, a
   supplier form, an NDA, a W-8/W-9 equivalent, a VPAT. Send it with the first email
   rather than after the quote; it shortens the round trip considerably.

**Expected response time:** one business day for a first reply, three business days for a
written quote. This matches what the commercial page publicly commits to; the two must not
drift apart.

---

## What a commercial licence includes

| | |
|---|---|
| **Licence grant** | A non-exclusive, non-transferable right for the named entity and its majority-owned affiliates to use, install and deploy Goel° for commercial purposes, for the seat count and term purchased. |
| **Scope** | Internal business use, including managed-fleet deployment via MDM and headless `GoelDaemon` on your own infrastructure. Redistribution, resale, sublicensing and OEM bundling are **not** included by default and are quoted separately. |
| **Invoice** | A proper VAT/GST-compliant invoice from a named legal entity, payable by bank transfer, suitable for your accounts payable process. Purchase orders accepted. |
| **Term** | Annual subscription **or** perpetual licence. A perpetual licence never stops working and keeps the version stream you bought; an annual licence keeps rolling forward with new releases. |
| **Update entitlement** | Annual: all releases published during the paid term. Perpetual: all releases published in the 12 months from purchase, and those releases remain yours to run indefinitely. |
| **Support** | Email support with a defined response target, direct to the author — not a ticket queue. Tiers and targets are set out in the quote. |
| **Compliance pack** | On request: SBOM, third-party licence inventory, security questionnaire answers, and the vendored-dependency CVE policy in [SECURITY.md](SECURITY.md). |
| **Warranty & liability** | The commercial agreement replaces PolyForm's "as is, no liability" terms with negotiated warranty and liability provisions. This is usually the real reason a company needs the paid licence. |

### What it does **not** include

- **The Goel° name, the g° mark, the app icon, or any branding.** Those are reserved
  under [TRADEMARK.md](TRADEMARK.md) and are not licensed by either the PolyForm licence
  or a commercial agreement. A separate written permission is required.
- **Source-code ownership or exclusivity.** You are buying a licence, not the copyright.
- **Bespoke development.** Feature work can be commissioned, but it is quoted separately.

---

## Pricing

`TODO(owner)` — publish at least an indicative band here. Companies that cannot form a
rough budget estimate from a public page frequently do not send the email at all, which
costs far more than the discount a published price implies.

---

## A note on the older releases

The git tags **`v1.0.0`** and **`v1.0.1`** were published under the MIT licence. That
grant is irrevocable: anyone who obtained those releases keeps their MIT rights to those
releases, forever, including for commercial use. Nothing here retroactively changes that,
and no one is going to pretend otherwise.

The PolyForm licence applies from the **next release onward**. If you need a supported,
current, security-patched Goel° for commercial use, that is what the commercial licence
is for.

---

## Questions this file does not answer

If your legal team has a question that is not covered here, send it to the licensing
address above. Getting the answer in writing before you buy is entirely reasonable and
we would rather do that than argue about it later.
