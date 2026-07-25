# Trademark and Branding Policy — Goel°

**Short version:** the code is licensed. The name and the mark are not.

The [PolyForm Noncommercial License](LICENSE) — and any [commercial licence](LICENSE-COMMERCIAL.md)
purchased on top of it — grants rights to the **software**. Neither grants any right to
use the Goel° name, the g° mark, or the visual identity. Those are reserved separately
and always have been. Copyright and trademark are different bodies of law, and a copyright
licence is silent on trademarks unless it says otherwise. This file is what says otherwise.

---

## What is reserved

- **The name "Goel°"** and the plain-text form "Goel", when used to identify download
  management software.
- **The g° mark** — the lowercase "g" monogram with the raised accent dot.
- **The application icon**, in all its variants, including the sky-blue squircle treatment
  in `Assets/AppIcon-*.png`.
- **The product names** `GoelDownloader`, `GoelDaemon`, and "Goel° Web".
- **The bundle identifier** `com.goel.downloader` and the `goel://` URL scheme, insofar
  as they identify the official product to macOS and to users.
- **The trade dress** of the website and the app — the specific combination of the mark,
  wordmark, colour treatment and layout that a user recognises as "this is Goel°".

Reserved by Vinit Kumar Goel. Registration status: `TODO(owner)` — state here whether any
of the above is a registered trademark in any jurisdiction, or whether the claim rests on
unregistered/common-law rights. Both are worth having; being straight about which you have
is worth more than implying a registration you do not hold.

---

## What you may do without asking

- **Refer to Goel° by name**, accurately, in prose — reviews, blog posts, comparison
  tables, documentation, conference talks, "works with Goel°", "we evaluated Goel°".
  Nominative use is fine and we are glad of it.
- **Link to the project** using its name and, where the platform requires an image, its
  icon — for example in a link preview, an awesome-list entry, or a package index page.
- **Distribute the official, unmodified builds** with their branding intact, as permitted
  by whichever code licence applies to you.
- **Screenshot the app** for reviews, tutorials, bug reports and documentation.
- **Say your product integrates with Goel°**, if it does, without implying that we
  endorse, sponsor, or maintain your product.

---

## What requires written permission

- **Naming a fork, derivative, repackage or rebuild "Goel"**, or anything close enough
  that a user could mistake it for the official product — "Goel Plus", "Goel Pro",
  "OpenGoel", "goel-downloader-ce", `com.goel.*` bundle identifiers.
- **Using the g° mark or the app icon** in your own product, its icon, its store listing,
  or its marketing.
- **Using the name or mark in a domain name, package name, app-store listing, social
  media handle, or company name.**
- **Merchandise** — stickers, shirts, anything sold or given away carrying the mark.
- **Implying endorsement, partnership, certification or official status**, including
  phrases like "official Goel° build", "Goel° certified", or "Goel° for Enterprise" if it
  is not.

For any of the above, ask: licensing@vinitk.dev. Permission is often given
for community projects; it just has to be given.

---

## Forks

Forking is permitted by the code licence, within its noncommercial field of use. This
section is about what a fork must do with the branding.

**A fork must:**

1. **Choose its own name and its own icon.** Not a variation of Goel°, not the same
   monogram in a different colour. Something a user cannot confuse with the original.
2. **Change the bundle identifier** away from `com.goel.downloader`, and change or remove
   the `goel://` URL scheme registration, so the two apps do not fight over the same OS
   registrations on a machine that has both.
3. **Remove the Goel° icon assets** from the distributed build.
4. **Keep the copyright notices and the PolyForm licence terms**, as the licence requires,
   including the `Required Notice:` line in [LICENSE](LICENSE).
5. **State clearly that it is an unofficial derivative** and that it is not maintained,
   supported or endorsed by the Goel° author.

**A fork may** say, factually, "derived from Goel° by Vinit Kumar Goel" — that is accurate
attribution, and the licence's notice requirement effectively expects it. What it may not
do is present itself *as* Goel°.

The point is not to make forking hard. The point is that when a user reports a bug, files
a security advisory, or complains publicly, everyone can tell whose software they were
actually running.

---

## Why this exists

Once commercial licences are being sold, the name is the only thing that tells a buyer
they are dealing with the author and getting the support, updates and warranty they paid
for. If anyone can ship "Goel°", that assurance is worthless — and the first time a
rebranded fork ships something harmful, the reputational damage lands on the original.

Reserving the mark protects users more than it protects the author.

---

## Enforcement

If you are using the name or mark in a way this policy does not permit, you will get an
email asking you to change it, with a reasonable period to do so. Nobody's first contact
here is going to be a lawyer's letter. Please just answer the email.

Questions: licensing@vinitk.dev
