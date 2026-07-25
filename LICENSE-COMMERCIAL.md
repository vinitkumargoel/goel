# Commercial Licence — Goel°

Goel° is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).
That licence is generous for individuals and free forever for personal use, but it grants
**no rights at all for commercial purposes**. If your use is commercial, you need a
separate, paid commercial licence from the author.

This document explains who needs one, how to get one, and what you get for the money.

> **Note for the maintainer:** the licensing address and the indicative price bands below
> are filled in and match the commercial page. The one item still outstanding is the
> **named legal entity and registered address** that will appear on the licence and the
> invoice — decide that before issuing the first quote. Nothing in this file is a binding
> offer; final terms are the written quote.

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
- You **deploy Goel° to a business's managed fleet** — MDM, Jamf, Intune, Munki, a golden
  image, a Docker image, or `GoelDaemon` running on shared or company-owned
  infrastructure. The deployment mechanism is not itself what triggers this: a charity,
  school or public body that manages its own machines the same way is still permitted by
  PolyForm's *Noncommercial Organizations* clause and owes nothing.
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

Indicative bands, so you can put a number in a budget request before contacting anyone:

| Tier | Indicative price | Who it is for |
|---|---|---|
| **Personal** | Free forever | Individuals, students, hobbyists, home labs — plus charities, schools and public bodies, which the licence already covers at no cost. |
| **Business** | from ~$40–60 per seat, perpetual | Teams and companies up to roughly 250 seats. One-off payment; the version you buy is yours to keep and run indefinitely. |
| **Enterprise** | from ~$5,000 per year, unlimited site licence | Whole-organisation coverage at the licensed entity, plus the artefacts procurement and IT need to deploy at scale. |

These are indicative, not a binding offer; final pricing is confirmed in a written quote.
Multi-year terms, reduced rates for the commercially directed work of an academic or
non-profit institution, and currencies other than USD are available on request. These
bands must stay in step with the [commercial page](https://goel.vinitk.dev/commercial);
the two must not drift apart.

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
