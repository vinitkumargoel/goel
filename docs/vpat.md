# Accessibility Conformance Report — Goel°

**Voluntary Product Accessibility Template® (VPAT®) — WCAG 2.1 / Revised Section 508 Edition**

| | |
|---|---|
| **Name of product** | Goel° — download manager for macOS |
| **Version evaluated** | Working build from `main`, macOS 14+ (arm64) |
| **Product description** | A desktop application that queues, schedules and manages downloads over HTTP, FTP/FTPS, SFTP, BitTorrent and HLS, with an optional local web portal. |
| **Report date** | 2026-07-25 |
| **Contact** | See `docs/README.md` for the maintainer contact address. |
| **Notes** | This report covers the **macOS application**. The embedded web portal (Settings ▸ Web Access) is a separate surface and has **not** been evaluated; see [Scope and exclusions](#scope-and-exclusions). |

---

## Read this first

This document is written to be *useful in procurement*, which means it is written
to be **accurate rather than flattering**. Several criteria below are marked
"Partially Supports" or "Not Evaluated" where a more optimistic reading was
available. Specific measured numbers are given for every contrast claim so a
reviewer can check them independently.

If you are evaluating Goel° for a programme with a hard accessibility bar, the
[Known defects](#known-defects) section is the part to read. Nothing in it is
hidden elsewhere in the tables.

---

## Evaluation methods used

| Method | Applied? | Detail |
|---|---|---|
| Source-level audit of every SwiftUI view | Yes | All 36 files under `Sources/GoelApp/Views/` plus `Theme.swift` were read and annotated. |
| Programmatic colour-contrast measurement | Yes | WCAG 2.1 §1.4.3 relative-luminance arithmetic applied to all four theme palettes against their canvases, to filled-chip ink, and to the type-badge gradients. Ratios quoted below are computed, not estimated. |
| Static checks for unlabelled controls | Yes | Every `Image`-in-`Button`, `labelsHidden()` control, `TextEditor`, `SecureField`, `Stepper` and hand-drawn `Shape` control was located and reviewed individually. |
| Keyboard-path review of every interactive surface | Yes | By reading focus, `keyboardShortcut`, `onKeyPress` and `focusable` usage. |
| **Manual VoiceOver session on hardware** | **No** | Not performed as part of this evaluation. |
| **Manual keyboard-only session on hardware** | **No** | Not performed as part of this evaluation. |
| **Third-party / independent audit** | **No** | None has been commissioned. |
| **Automated accessibility scanner (e.g. Accessibility Inspector audit)** | **No** | Not run as part of this evaluation. |

**This matters and is stated plainly:** the conformance levels below are derived
from a code-level audit and computed contrast values. They have **not** been
confirmed by a screen-reader user driving the shipping application. Any criterion
whose real answer depends on runtime behaviour — announcement ordering, focus
restoration after a sheet closes, rotor behaviour — is therefore marked
**"Partially Supports"** or **"Not Evaluated"** rather than "Supports", even where
the code looks correct. Treat this report as a good-faith engineering statement,
not as a tested certification.

---

## Conformance terms

| Term | Meaning |
|---|---|
| **Supports** | The functionality of the product meets the criterion without known defects. |
| **Partially Supports** | Some functionality of the product does not meet the criterion. |
| **Does Not Support** | The majority of product functionality does not meet the criterion. |
| **Not Applicable** | The criterion is not relevant to the product. |
| **Not Evaluated** | The product has not been evaluated against the criterion. Used only for WCAG Level AAA and for criteria whose answer requires runtime testing that was not performed. |

---

## Applicable standards

- **WCAG 2.1** Level A and Level AA (W3C Recommendation, June 2018)
- **Revised Section 508** (36 CFR Part 1194, Appendix A–C)
- **EN 301 549 V3.2.1** — Chapter 11 (software) tracks WCAG 2.1 A/AA; the WCAG
  table below is the substantive answer for EN 301 549 clause 11 as well.

---

## Table 1 — Success Criteria, Level A

| Criterion | Conformance | Remarks |
|---|---|---|
| **1.1.1 Non-text Content** | Partially Supports | Every icon-only control in the application now carries an explicit accessible name — pause/resume/retry/reveal, remove, sort headers, the speed-limit "snail", the detail-panel toggle, sidebar filters, SFTP toolbar actions, palette rows, checklist checkboxes and stepper controls. Purely decorative graphics (gradient type tiles, drop-target outlines, dialog scrims, the dashed drop basket border) are explicitly hidden from assistive technology via `accessibilityHidden`. The QR code in Settings ▸ Web Access exposes the URL it encodes. **Defect:** not verified against a live screen reader; see Evaluation methods. |
| **1.2.1 Audio-only / Video-only (Prerecorded)** | Not Applicable | The product does not author or supply media. The built-in player plays files the user has downloaded; alternatives for that content are outside the product's control. |
| **1.2.2 Captions (Prerecorded)** | Not Applicable | As 1.2.1. The player is AVKit's `VideoPlayer`, which surfaces whatever caption tracks the user's own media file contains, using the system caption appearance settings. |
| **1.2.3 Audio Description or Media Alternative** | Not Applicable | As 1.2.1. |
| **1.3.1 Info and Relationships** | Partially Supports | Section headings across the sidebar, Settings panes, sheets and detail tabs carry the header trait, so the VoiceOver rotor can jump between them. Composite rows (a download row, a server row, a transfer row, a settings row, a palette row, a stat card, a chart column) are grouped into single elements with a coherent name and value rather than being read as loose fragments. Every `labelsHidden()` control in Preferences receives the name of its row through a SwiftUI environment value, so ~150 otherwise-anonymous switches and fields are named. **Defect:** the relationship between a settings row's *explanatory* text and its control is conveyed as a hint, not as a formal description relationship. |
| **1.3.2 Meaningful Sequence** | Partially Supports | Reading order follows the visual layout in every view, because the views are laid out with ordinary stacks and no absolute positioning. No explicit `accessibilitySortPriority` ordering has been applied, and traversal order has not been confirmed on hardware. |
| **1.3.3 Sensory Characteristics** | Supports | No instruction in the interface depends on shape, size, or position alone. |
| **1.4.1 Use of Color** | Partially Supports | Colour-only signals were identified and given a non-colour equivalent: the sidebar's 7-point server reachability dot now speaks "Online"/"Offline"/"Checking" with the failure reason; selected rows carry the selection trait rather than only an accent wash; destructive buttons and menu rows announce "destructive" rather than relying on red; the speed-limit toggle announces on/off rather than relying on an orange fill. **Defect:** the BitTorrent piece map distinguishes complete / partial / not-started blocks by colour alone *visually*; the map as a whole speaks its distribution ("N of M blocks complete, P in progress, Q not started"), but an individual block's state is not separately reachable. |
| **1.4.2 Audio Control** | Not Applicable | The product plays no audio automatically. Playback in the built-in player is user-initiated and stops when the window closes. |
| **2.1.1 Keyboard** | Partially Supports | The download queue is fully keyboard-driven: arrow keys move the selection, shift with an arrow (or home/end) extends it, ⌘A selects all and ⇧⌘A deselects, escape clears the selection, space previews via Quick Look, return performs the row's primary action. The command palette (⌘K) is keyboard-complete including arrow navigation and escape. Search is reachable with ⌘F. Sheets and dialogs bind return and escape. Menu-bar commands cover add (⌘N), link grabber (⌘⇧L), paste (⌘⇧V), history (⌘Y), detail panel (⌘I / ⌘⌥I), drop basket (⌘⇧B), select all (⌘A) and deselect all (⌘⇧A), and the palette (⌘K). The first-run onboarding flow can be advanced with return and dismissed with escape. **Defect:** the floating **Drop Basket** accepts pointer drag-and-drop only and has no keyboard equivalent within that panel — the same outcome is reachable elsewhere (⌘N, ⌘⇧V, the palette), but the control itself is not operable by keyboard. |
| **2.1.2 No Keyboard Trap** | Not Evaluated | No construct in the source suggests a trap — every modal binds escape and every popover dismisses — but this was not confirmed on hardware. |
| **2.1.4 Character Key Shortcuts** | Supports | All application shortcuts require ⌘ or ⌘⇧. The only unmodified keys used (arrows, space, return, escape) are consumed inside a focused list or field, in the conventional way. |
| **2.2.1 Timing Adjustable** | Supports | The product imposes no time limit on any user interaction. Success banners fade, but every message they carry is also announced to assistive technology at the moment it appears, and no action is lost when one disappears. |
| **2.2.2 Pause, Stop, Hide** | Partially Supports | Auto-updating content is limited to progress readouts, which are exempt as activity indicators; live-updating elements are marked `updatesFrequently` so a screen reader can manage re-announcement. **Defect:** the product does not honour the system **Reduce Motion** setting. A handful of eased transitions (panel show/hide, list scroll-to-selection, ring fill, palette highlight) play regardless. None loops, none lasts beyond ~0.4 s, and none is parallax or flashing. |
| **2.3.1 Three Flashes or Below** | Supports | Nothing in the interface flashes. The one indeterminate progress element is a static 40 %-width bar, not a strobe. |
| **2.4.1 Bypass Blocks** | Not Applicable | Single-window desktop application; no repeated navigation blocks in the web-page sense. Section headers throughout give the rotor a skip mechanism. |
| **2.4.2 Page Titled** | Supports | Every window, sheet and panel has a title; the floating drop-basket panel and the built-in player window are titled. |
| **2.4.3 Focus Order** | Partially Supports | Focus follows layout order, which matches meaning in every view reviewed. Focus is explicitly placed on the search field when the command palette opens and returned to it after clearing. **Defect:** focus restoration after a sheet or popover is dismissed relies on system default behaviour and has not been verified on hardware. |
| **2.4.4 Link Purpose (In Context)** | Supports | Ambiguous button names were replaced with names that state their target: "Show" → "Show drop basket", "Set" → "Set portal password", "Open" → "Open web portal in browser", "Retry" → "Retry transfer of ‹file›", "Cancel" → "Cancel transfer of ‹file›", "Clear" → "Clear finished transfers", and so on. The onboarding licence link states its destination. |
| **3.1.1 Language of Page** | Supports | The application declares its language through the standard macOS localisation mechanism. |
| **3.2.1 On Focus** | Supports | No control initiates a change of context on receiving focus. |
| **3.2.2 On Input** | Supports | Changing a setting applies that setting; it does not navigate or open a window. Rows that reveal dependent settings (e.g. "Require sign-in" revealing username/password) expand in place. |
| **3.3.1 Error Identification** | Supports | Errors are stated in text, not by icon or colour alone. Failure states in the add sheet, the SFTP connection editor, the media-format picker and the playlist checklist announce "Error…" / "Connection test failed…" / "Couldn't load…" in words, in addition to their warning glyph and tint. |
| **3.3.2 Labels or Instructions** | Partially Supports | Every input in Preferences, the sheets, and the SFTP editor has a programmatic label. Text fields whose only visible name was a placeholder (search fields, the paste box, the checksum field, the cookie header field) received explicit labels, because a placeholder disappears the moment the field has content. **Defect:** the explanatory sentence under each settings row is exposed as a hint, which some assistive-technology configurations suppress. |
| **4.1.1 Parsing** | Not Applicable | Not a markup-based technology. (This criterion is also obsolete in WCAG 2.2.) |
| **4.1.2 Name, Role, Value** | Partially Supports | Hand-drawn controls that replace system ones were given the role and value they impersonate: the custom `Dropdown` announces as a pop-up button with its current choice; the hand-built confirmation dialog carries the modal trait so a screen reader is confined to it; the segmented profile picker and the format-picker radio rows carry the selected trait; the speed-limit "snail" — a bare `Shape` — announces a name, a button role and an on/off value; the stepper reports its numeric value, which lives in a sibling label visually. Progress elements announce a spoken value ("62 percent, 4.2 megabytes of 6.8 gigabytes, about 6 minutes remaining"). **Defect:** roles are asserted through SwiftUI traits and have not been confirmed in the accessibility tree on hardware. |

---

## Table 2 — Success Criteria, Level AA

| Criterion | Conformance | Remarks |
|---|---|---|
| **1.2.4 Captions (Live)** | Not Applicable | No live media. |
| **1.2.5 Audio Description (Prerecorded)** | Not Applicable | See 1.2.1. |
| **1.3.4 Orientation** | Not Applicable | Desktop application; orientation is not restricted. |
| **1.3.5 Identify Input Purpose** | Partially Supports | Password and secure fields use `SecureField`, so the platform treats them as credentials. Autofill-purpose metadata is not otherwise declared, as the inputs are host/proxy/API configuration rather than personal data about the user. |
| **1.4.3 Contrast (Minimum)** | **Partially Supports** | All four themes were measured. **Fixed in this release:** ink on filled chips is now derived from the fill instead of hard-coded white — the selected sidebar row, the selected server row, the active speed-profile pill, the primary and destructive dialog buttons, and the sheet/onboarding header tiles previously measured **1.93–2.77:1** and now measure **5.87–9.82:1**. Frost Light's green, orange and yellow were darkened one step (3.76 / 4.38 / 4.16 → **4.54 / 4.52 / 4.51:1**). Nord's Aurora orange and purple were lifted one step (4.39 / 4.41 → **4.61 / 4.63:1**). Secondary ink on a filled row moved from `white @ 0.6–0.75` (worst 3.75:1) to a derived ink at 0.85 (worst **4.73:1**). Every semantic colour now clears 4.5:1 as text on its own theme's canvas. **Residual defect:** the small protocol badge ("HTTP", "BT", "HLS") draws its text over a tint of the same colour. Reducing that tint from 20 % to 12 % moved the range from 2.94–4.20:1 to **3.83–7.95:1**, which clears 4.5:1 in Frost Dark and in Dracula but still falls short in Frost Light (3.87–4.35:1) and Nord (3.83–3.94:1). Fixing it properly requires a palette change beyond the scope of this pass. The information is redundant — the same protocol is spoken by the row's accessible name and shown in the detail panel — but the badge itself does not meet AA in two of four themes. |
| **1.4.4 Resize Text** | Partially Supports | The application's type is drawn at deliberately non-standard sizes (9–16 pt) that sit between the system text styles. Rather than leave those fixed, a scaled-font modifier was introduced that multiplies each size by the user's macOS **Accessibility ▸ Display ▸ Text size** factor, and it has been applied to **151 text sites** — the download list rows and header, both detail panels and all detail tabs, the sidebar, the status bar, the menu-bar popover, history, the Settings scaffolding and rows, the media/playlist pickers, the SFTP connection editor, the statistics sheet and the onboarding flow. Glyph-only chrome keeps fixed sizes deliberately, since scaling a 7 pt chevron helps nobody and breaks the layout. **Defect:** reflow at the largest text sizes has not been verified on hardware; some fixed-width columns (the 84 pt speed columns, the 22 pt stepper readout) may clip before 200 %. |
| **1.4.5 Images of Text** | Supports | One exception, handled: the menu-bar item draws its two speed lines into a bitmap because macOS clips a two-line SwiftUI label there. That image carries an accessible label restating both rates in words. |
| **1.4.10 Reflow** | Not Evaluated | Not verified. The application is resizable and uses flexible stacks throughout, but behaviour at extreme sizes combined with the largest text setting was not tested. |
| **1.4.11 Non-text Contrast** | **Partially Supports** | Interactive-component boundaries use a hairline at 10 % of the foreground colour, which does not reach 3:1 on its own; component identification rests on fill and text rather than border. Status colours all clear 3:1 against their canvas. **Defect:** the coloured file-type tiles carry a white glyph over a gradient, measuring **1.72–3.65:1** at their lightest ends (worst: the "archive" and "app" tiles). These tiles are marked decorative and hidden from assistive technology, and the same information is present in the file name and in the spoken row label, so no information is conveyed by the tile alone — but as drawn they do not meet 3:1. |
| **1.4.12 Text Spacing** | Not Evaluated | The platform does not expose user text-spacing overrides in the way a browser does; not tested. |
| **1.4.13 Content on Hover or Focus** | Partially Supports | Hover tooltips are used widely. Every tooltip whose content was *not* otherwise available was duplicated into an accessible hint or label — notably the MDM "managed by your organisation" explanation on locked settings, the server reachability reason, and the per-column sort direction. **Defect:** tooltips remain pointer-triggered and are not dismissible with escape while shown. |
| **2.4.5 Multiple Ways** | Not Applicable | Desktop application, not a set of web pages. In practice most destinations are reachable by menu, keyboard shortcut and the ⌘K palette. |
| **2.4.6 Headings and Labels** | Supports | Headings describe their section and labels describe their control. All-caps visual headings ("SERVERS", "PROXY") are spoken in natural case so screen readers do not spell them out. |
| **2.4.7 Focus Visible** | Partially Supports | System focus rings are used by default. **Defect:** the download list disables its focus effect (`focusEffectDisabled`) so the list's own selection highlight is the focus signal. That highlight is a 22 %-opacity accent wash, which is a weak focus indicator; the selection *is* announced, but a sighted keyboard user gets a subtler cue than the platform default. |
| **3.1.2 Language of Parts** | Not Applicable | Single language per run. |
| **3.2.3 Consistent Navigation** | Supports | Sidebar, toolbar, status bar and detail panel keep the same position and behaviour throughout. |
| **3.2.4 Consistent Identification** | Supports | The same action carries the same name everywhere — the row state button's name is derived from the same branch that chooses its glyph, so name and behaviour cannot drift. |
| **3.3.3 Error Suggestion** | Supports | Failures state a remedy where one exists (SFTP connection failures lead with the actionable cause and keep the library's own wording subordinate; a rekeyed host offers the pin reset; a missing ffmpeg says which binary was resolved and why). |
| **3.3.4 Error Prevention (Legal, Financial, Data)** | Supports | Destructive actions (removing a download, deleting a saved login, regenerating the API token, resetting a pinned host key, overwriting on upload) are confirmed first, and the confirmation dialog is modal to assistive technology and announces its destructiveness in words. |
| **4.1.3 Status Messages** | Partially Supports | Transient feedback that never takes focus — success toasts, settings banners — is posted to the platform announcement channel so it is spoken. Live-updating readouts carry the `updatesFrequently` trait. **Defect:** not every asynchronous result is announced; in particular the SFTP connection-test result panel and the media-format picker's load outcome appear without an explicit announcement, relying on the user navigating to them. |

---

## Table 3 — Revised Section 508, Chapter 3 (Functional Performance Criteria)

| Criterion | Conformance | Remarks |
|---|---|---|
| **302.1 Without Vision** | Partially Supports | Every control has a name, composite rows read as single coherent items, progress is spoken as a value, and the queue is navigable by keyboard. Not confirmed with a screen reader on hardware. The Drop Basket is not operable without a pointer (alternatives exist). |
| **302.2 With Limited Vision** | Partially Supports | Text scales with the system text-size setting at 151 sites; all four theme palettes clear 4.5:1 for text on canvas; filled-chip ink is derived rather than assumed. Residual sub-AA cases: the protocol badge in two themes, the decorative type tiles. |
| **302.3 Without Perception of Color** | Partially Supports | Colour-only signals were given text or trait equivalents. Residual: individual piece-map blocks. |
| **302.4 Without Hearing** | Supports | No information is conveyed by sound. |
| **302.5 With Limited Hearing** | Supports | As 302.4. |
| **302.6 Without Speech** | Supports | No speech input is required. |
| **302.7 With Limited Manipulation** | Partially Supports | Keyboard paths exist for the primary workflows. Drag-and-drop is offered as a convenience, and the Drop Basket is drag-only. |
| **302.8 With Limited Reach and Strength** | Supports | No sustained or simultaneous physical action is required. |
| **302.9 With Limited Language, Cognitive, and Learning Abilities** | Partially Supports | Plain-language error messages, a first-run walkthrough, per-setting explanations, and a searchable command palette. No reading-level testing was performed. |

---

## Table 4 — Revised Section 508, Chapter 5 (Software)

| Criterion | Conformance | Remarks |
|---|---|---|
| **502.2.1 User Control of Accessibility Features** | Supports | The application does not disrupt platform accessibility features. |
| **502.2.2 No Disruption of Accessibility Features** | Supports | As above. |
| **502.3 Accessibility Services** | Partially Supports | The application is built on SwiftUI and exposes the platform accessibility API. Object information, row/column relationships, values, state, and actions (including a custom "Edit server" action on sidebar rows) are provided. Not verified in the live accessibility tree. |
| **502.4 Platform Accessibility Features** | Supports | Honours the system text-size setting, the system caption appearance for played media, and the system light/dark appearance. **Does not** honour Reduce Motion (see 2.2.2). |
| **503.2 User Preferences** | Supports | Uses platform text, colour and appearance settings rather than overriding them; the four themes are an addition on top, not a replacement. |
| **503.3 Alternative User Interfaces** | Not Applicable | No alternative interface is provided in place of the accessible one. |
| **503.4 User Controls for Captions and Audio Description** | Not Applicable | The product does not author media. |
| **504.x Authoring Tools** | Not Applicable | Goel° is not an authoring tool. |

---

## Table 5 — Revised Section 508, Chapter 6 (Support Documentation and Services)

| Criterion | Conformance | Remarks |
|---|---|---|
| **602.2 Accessibility and Compatibility Features** | Supports | This document, plus the user documentation under `docs/`, describes the accessibility features and their limits. |
| **602.3 Electronic Support Documentation** | Partially Supports | Documentation is plain Markdown, which is well supported by assistive technology. It has not been separately audited against WCAG. |
| **602.4 Alternate Formats for Non-Electronic Support Documentation** | Not Applicable | No printed documentation is supplied. |
| **603.2 Information on Accessibility and Compatibility Features** | Supports | Support contact is published; accessibility questions are answered through the same channel. |
| **603.3 Accommodation of Communication Needs** | Supports | Support is conducted in writing by email, which accommodates most communication needs. |

---

## Known defects

Consolidated, so nothing has to be pieced together from the tables above.

1. **No screen-reader or keyboard-only session has been run on hardware.** Every
   claim above derives from source review and computed contrast. This is the
   single biggest limitation of this report.
2. **Protocol badge contrast** — the "HTTP" / "BT" / "HLS" chip measures
   3.87–4.35:1 in Frost Light and 3.83–3.94:1 in Nord, below the 4.5:1 needed for
   9 pt text. Improved from 2.94–4.20:1 but not resolved. Information is redundant.
3. **File-type tile contrast** — the white glyph on the archive / app / disc-image
   gradients measures 1.72–2.87:1, below the 3:1 for graphical objects. The tiles
   are hidden from assistive technology and the information is available in text,
   so nothing is lost, but the graphic itself is sub-threshold.
4. **Drop Basket is pointer-only.** The floating panel accepts drag-and-drop and
   nothing else. Equivalent outcomes are reachable by ⌘N, ⌘⇧V and ⌘K.
5. **Reduce Motion is not honoured.** Short eased transitions play regardless of
   the system setting.
6. **Focus visibility in the download list** is carried by a 22 %-opacity
   selection wash rather than the platform focus ring.
7. **Piece-map blocks** are individually distinguished by colour alone; the map
   speaks its aggregate distribution rather than per-block state.
8. **Not every asynchronous result is announced** — notably the SFTP
   connection-test outcome and the media-format load outcome.
9. **Reflow and clipping at the largest text sizes are unverified**; some
   fixed-width columns may truncate.

## Planned remediation

In the order a procurement reviewer is likely to care about them:

1. A recorded VoiceOver and keyboard-only pass over the primary workflows, and
   an update to this document with what it finds. This converts most
   "Partially Supports" entries into a tested answer either way.
2. Honour Reduce Motion.
3. Re-tune the protocol badge so it clears 4.5:1 in all four themes.
4. Add a keyboard route into the Drop Basket, or document it as a
   pointer-only convenience in the user documentation.
5. Announce asynchronous results that appear without taking focus.
6. Restore the platform focus ring, or strengthen the list's own focus cue, in
   the download queue.

## Scope and exclusions

- **The embedded web portal** (Settings ▸ Web Access) serves a browser UI on the
  local network. It is a **separate codebase and a separate surface**, has not
  been evaluated, and **is not covered by any statement in this report**. Do not
  read this document as a conformance claim about the portal.
- **The browser extension** and the **headless Linux daemon** are likewise out of
  scope.
- Content the product downloads and plays is the user's own and is outside the
  product's control.

## Legal note

This is a voluntary, good-faith self-assessment prepared from a source-level
audit. It is not a certification, it is not the result of an independent
third-party evaluation, and it is not a warranty. Where it says "Partially
Supports" or "Not Evaluated", that is the honest answer and should be read as
such. Corrections and test findings are welcome at the support address in
`docs/README.md`.

VPAT® is a registered service mark of the Information Technology Industry Council (ITI).
