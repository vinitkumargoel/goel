# Accessibility Conformance Report — Goel°

**Voluntary Product Accessibility Template® (VPAT®) — WCAG 2.1 / Revised Section 508 Edition**

| | |
|---|---|
| **Name of product** | Goel° — download manager for macOS |
| **Version evaluated** | Working build from `main` (Studio interface), macOS 14+ (arm64) |
| **Product description** | A desktop application that queues, schedules and manages downloads over HTTP, FTP/FTPS, SFTP, BitTorrent and HLS, with an optional local web portal. |
| **Report date** | 2026-10-03 |
| **Contact** | See `docs/README.md` for the maintainer contact address. |
| **Notes** | This report covers the **macOS application**. The embedded web portal (Settings ▸ Web Access) is a separate surface and has **not** been evaluated; see [Scope and exclusions](#scope-and-exclusions). |

---

## Read this first

This document is written to be *useful in procurement*, which means it is written
to be **accurate rather than flattering**. Several criteria below are marked
"Partially Supports" or "Not Evaluated" where a more optimistic reading was
available. Every contrast figure quoted was computed from the design tokens; where
something was not measured, the report says so instead of estimating.

If you are evaluating Goel° for a programme with a hard accessibility bar, the
[Known defects](#known-defects) section is the part to read. Nothing in it is
hidden elsewhere in the tables.

---

## Evaluation methods used

| Method | Applied? | Detail |
|---|---|---|
| Source-level audit of the SwiftUI interface | Yes | The Studio interface under `Sources/GoelApp/UI/` (187 files: design system, main window, downloads, detail, add flow, settings, SFTP, auxiliary windows) was reviewed. Colours come from the `Studio.Palette` tokens in `UI/DesignSystem/StudioPalette.swift`. |
| Programmatic colour-contrast measurement | Partly | WCAG 2.1 §1.4.3 relative-luminance arithmetic applied to the palette's text and indicator tokens in all four appearances (Light, Dark, Light + Increase Contrast, Dark + Increase Contrast), with translucent tokens composited over their surface. Ratios in this report are computed, not estimated. Artwork, badges and per-file-type tints were **not** measured. |
| Automated guards in the test suite | Yes | Unit tests enforce minimum contrast for the core text tokens and for the focus ring, that text follows the text-size setting (`FontScalingDriftTests`), and that focus rings are read from the focused control (`FocusRingPlacementTests`). |
| Static checks for unlabelled controls | Yes | Icon-only controls go through `StudioIconButton`, which requires a label; hand-drawn controls were reviewed individually. |
| Keyboard-path review of every interactive surface | Yes | By reading focus, `keyboardShortcut`, `onKeyPress`, `onMoveCommand` and `focusable` usage. |
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

## Appearance

The interface has one design (Studio) in **Light** and **Dark**, chosen in
Settings ▸ General (System / Light / Dark) or with ⇧⌘T. Every colour token also
has an **Increase Contrast** variant, used automatically when the macOS
*Increase contrast* setting is on. The older palette themes (Frost, Dracula, Nord)
no longer exist; a stored choice of one of them opens as Light or Dark.

Measured contrast of the core tokens (Light / Dark / Light + Increase Contrast /
Dark + Increase Contrast):

| Foreground on surface | Ratios | Use |
|---|---|---|
| `ink` on canvas | 14.61 / 14.91 / 17.81 / 16.72 | primary text |
| `ink` on card | 15.87 / 12.82 / 19.35 / 14.37 | primary text |
| `ink2` on canvas | 6.75 / 8.94 / 12.45 / 12.83 | secondary text |
| `ink2` on card | 7.34 / 7.68 / 13.52 / 11.03 | secondary text |
| `ink3` on canvas | **3.92** / 5.53 / 8.39 / 9.88 | tertiary text: captions, placeholders, counts |
| `ink3` on card | **4.26** / 4.76 / 9.12 / 8.50 | tertiary text |
| `ink3` on well | **4.09** / 5.06 / 8.75 / 9.04 | tertiary text in footers and the status bar |
| `onAccent` on `accent` | 4.99 / 8.64 / 7.82 / 12.70 | primary buttons, selected chips |
| `accent` on card | 5.12 / 7.27 / 7.82 / 9.45 | accent text and glyphs |
| `bad` on card | 5.29 / 5.57 / 8.44 / 7.64 | error text |
| `warn` on card | **3.78** / 8.29 / 6.75 / 10.14 | warning text |
| `good` on card | **4.39** / 7.51 / 7.99 / 10.09 | success text, speeds |
| `hairlineStrong` on card | **1.53** / **1.55** / 5.91 / 5.60 | control borders |
| `focusRing` on canvas, card, rail, well | ≥ 3:1 in all four | keyboard focus ring (test-enforced) |

Bold figures are below the threshold that applies to them (4.5:1 for text,
3:1 for component boundaries).

---

## Table 1 — Success Criteria, Level A

| Criterion | Conformance | Remarks |
|---|---|---|
| **1.1.1 Non-text Content** | Partially Supports | Icon-only controls are built with `StudioIconButton`, which cannot be created without a label (spoken and shown as the tooltip). Hand-drawn controls carry explicit names: the row state button, the speed-limit control, rail items, filter chips, segment buttons, the piece map, the weekly profile grid. Decorative artwork (file-type artwork, scrims, drop-target outlines, swatches) is hidden from assistive technology. **Defect:** not verified against a live screen reader; see Evaluation methods. |
| **1.2.1 Audio-only / Video-only (Prerecorded)** | Not Applicable | The product does not author or supply media. The built-in player plays files the user has downloaded; alternatives for that content are outside the product's control. |
| **1.2.2 Captions (Prerecorded)** | Not Applicable | As 1.2.1. The player is AVKit's, which surfaces whatever caption tracks the user's own media file contains, using the system caption appearance settings. |
| **1.2.3 Audio Description or Media Alternative** | Not Applicable | As 1.2.1. |
| **1.3.1 Info and Relationships** | Partially Supports | Section headings (lane headers, settings groups, form-card titles, sheet titles, menu sections) carry the header trait. Composite rows — a download row or card, a server row, a transfer row, a settings row, a stat tile — are single elements with a coherent name and value. Unlabelled settings controls take their row's name from the environment. **Defect:** a settings row's explanatory text reaches its control as a hint, not as a formal description relationship. |
| **1.3.2 Meaningful Sequence** | Partially Supports | Reading order follows the visual layout, built from ordinary stacks. Traversal order has not been confirmed on hardware. |
| **1.3.3 Sensory Characteristics** | Supports | No instruction in the interface depends on shape, size, or position alone. |
| **1.4.1 Use of Color** | Partially Supports | Status chips pair colour with a word and a glyph. Selected rows carry the selection trait as well as their tint. Destructive buttons announce "destructive". The rail's server status differs in **shape** (haloed dot online, cross offline, hollow ring while checking) and, with *Differentiate without colour* on, shows a distinct symbol per state; it is also spoken. The weekly profile grid draws each profile's letter in its cells and on its brush swatch. **Defect:** the BitTorrent piece map distinguishes complete / partial / missing blocks by colour alone visually; the map as a whole speaks its distribution, but an individual block's state is not separately reachable. |
| **1.4.2 Audio Control** | Not Applicable | The product plays no audio automatically. Playback in the built-in player is user-initiated. |
| **2.1.1 Keyboard** | Partially Supports | The queue (board and list) is keyboard-driven: arrows move the selection (←/→ across board lanes), ⇧ with an arrow or Home/End extends it, ⌘A / ⇧⌘A select and deselect all, Esc clears the selection, Space previews with Quick Look, Return opens. Menu commands cover add (⌘N), link grabber (⇧⌘L), paste URLs (⇧⌘V), search (⌘F), history (⌘Y), sidebar (⌃⌘S), detail panel (⌘I), theme (⇧⌘T), drop basket (⇧⌘B), compact rows (⌥⌘C), command palette (⌘K), filters (⌘1…), pause / resume selected (⌘P / ⌥⌘P). The Studio pop-up menus (Dropdown, settings selects, the header's Sort / Group / Select / Type menus) take the keyboard when they open: ↑/↓ move, Home/End jump, Return or Space picks, Esc closes, typing jumps to a matching item. The settings sidebar moves with ↑/↓. The weekly profile grid has a cell cursor: arrows move, Space or Return paints with the brush, Delete clears, ⇧ with an arrow paints as it moves. RSS articles are buttons. Sheets bind Return and Esc. **Defect:** the floating **Drop Basket** accepts pointer drag-and-drop only; the same outcome is reachable with ⌘N, ⇧⌘V or ⌘K. Custom buttons are reached with Tab only when *Keyboard navigation* is on in macOS, as for native controls. |
| **2.1.2 No Keyboard Trap** | Not Evaluated | No construct in the source suggests a trap — every modal binds Esc and every popover dismisses — but this was not confirmed on hardware. |
| **2.1.4 Character Key Shortcuts** | Supports | Application shortcuts use ⌘ (with ⇧, ⌥ or ⌃). Unmodified keys (arrows, Space, Return, Esc, Delete, and type-to-select letters in an open menu) act only inside the focused list, grid or menu, in the conventional way. |
| **2.2.1 Timing Adjustable** | Supports | No time limit applies to any user interaction. Toasts fade, but their message is also announced when it appears and their actions are reachable elsewhere (Edit ▸ Undo). |
| **2.2.2 Pause, Stop, Hide** | Supports | Auto-updating content is limited to progress readouts, which are activity indicators; live readouts carry `updatesFrequently`. Transitions follow **Reduce Motion**: with it on, panels, segments, switches, toasts and progress sweeps change without animation (16 source files read the setting). Nothing loops indefinitely except the indeterminate spinner, which is an activity indicator. |
| **2.3.1 Three Flashes or Below** | Supports | Nothing in the interface flashes. |
| **2.4.1 Bypass Blocks** | Not Applicable | Single-window desktop application; no repeated navigation blocks in the web-page sense. Section headers give the rotor a skip mechanism. |
| **2.4.2 Page Titled** | Supports | Every window, sheet and panel has a title. |
| **2.4.3 Focus Order** | Partially Supports | Focus follows layout order. The queue takes focus when the window opens. The in-window confirmation dialog moves focus to its Cancel button when it opens and disables the window behind it, so keys and the selection menu commands cannot act on the queue while it is up; focus returns to the queue when it closes. Pop-up menus open on their current item. **Defect:** focus restoration after sheets and popovers otherwise relies on system behaviour and has not been verified on hardware. |
| **2.4.4 Link Purpose (In Context)** | Supports | Buttons state their target ("Retry transfer of ‹file›", "Open web portal in browser", "Clear finished transfers"); icon buttons' labels say what they do. |
| **3.1.1 Language of Page** | Supports | The application declares its language through the standard macOS localisation mechanism. |
| **3.2.1 On Focus** | Supports | No control initiates a change of context on receiving focus. |
| **3.2.2 On Input** | Supports | Changing a setting applies that setting; it does not navigate or open a window. Dependent settings expand in place. |
| **3.3.1 Error Identification** | Supports | Errors are stated in text, not by icon or colour alone (failure notes, status chips, field messages). |
| **3.3.2 Labels or Instructions** | Partially Supports | Inputs have programmatic labels; fields whose only visible name is a placeholder carry an explicit label. **Defect:** the explanatory sentence under a settings row is exposed as a hint, which some configurations suppress. |
| **4.1.1 Parsing** | Not Applicable | Not a markup-based technology. (This criterion is also obsolete in WCAG 2.2.) |
| **4.1.2 Name, Role, Value** | Partially Supports | Hand-drawn controls expose the role they impersonate: the Studio switch and checkbox are represented as toggles; `Dropdown` and the settings select are represented as a pop-up button (a `Picker`), so VoiceOver announces their name, current choice and that they open a list; segments, chips and radio rows carry the selected trait; the confirmation dialog is modal and announces its title and message when it opens; the weekly grid is adjustable and offers *Paint Hour* / *Clear Hour* actions; progress announces a spoken value. **Defect:** roles are asserted through SwiftUI and have not been confirmed in the live accessibility tree. |

---

## Table 2 — Success Criteria, Level AA

| Criterion | Conformance | Remarks |
|---|---|---|
| **1.2.4 Captions (Live)** | Not Applicable | No live media. |
| **1.2.5 Audio Description (Prerecorded)** | Not Applicable | See 1.2.1. |
| **1.3.4 Orientation** | Not Applicable | Desktop application; orientation is not restricted. |
| **1.3.5 Identify Input Purpose** | Partially Supports | Password fields use `SecureField`, so the platform treats them as credentials. Other inputs are host, proxy and API configuration rather than personal data about the user. |
| **1.4.3 Contrast (Minimum)** | **Partially Supports** | See [Appearance](#appearance) for the measured figures. Primary and secondary text, accent, error text and button labels clear 4.5:1 in all four appearances. **Defects (Light, without Increase Contrast):** tertiary text (`ink3`) measures 3.92–4.26:1 on canvas, card and well; warning text measures 3.78:1 and success text 4.39:1 on a card. All clear 4.5:1 in Dark and with Increase Contrast on. The protocol badge, file-type artwork and other tinted chips were **not measured** in this pass. |
| **1.4.4 Resize Text** | Partially Supports | Interface text is set through `.studioFont` / `.scaledFont`, which scale with the text-size setting (`@ScaledMetric(relativeTo: .body)`); a test fails the build on any unscaled system font size. Chrome that had fixed heights — the status bar, the list's column header, the SFTP toolbar, settings sidebar rows — now has minimum heights and grows; the confirmation dialog widens with the text size. **Defect:** whether the factor tracks the macOS *Text size* setting for this app's windows, and how layouts reflow at the largest sizes, has not been verified on hardware; fixed-width list columns may truncate. |
| **1.4.5 Images of Text** | Supports | One exception, handled: the menu-bar item draws its speed lines into a bitmap, which carries an accessible label restating both rates. |
| **1.4.10 Reflow** | Not Evaluated | The window is resizable and uses flexible stacks, but behaviour at small sizes with the largest text was not tested. |
| **1.4.11 Non-text Contrast** | **Partially Supports** | The keyboard focus ring clears 3:1 against canvas, card, rail and well in all four appearances (test-enforced). Status glyphs use the same tokens as status text (see above). **Defect:** control borders (`hairlineStrong`) measure about 1.5:1 in Light and Dark without Increase Contrast (5.6–5.9:1 with it); fields, cards and secondary buttons are identified by fill, elevation and text rather than by border. File-type artwork was not measured; it is decorative and its information is in the file name. |
| **1.4.12 Text Spacing** | Not Evaluated | The platform does not expose user text-spacing overrides in the way a browser does; not tested. |
| **1.4.13 Content on Hover or Focus** | Partially Supports | Tooltips whose content is not shown elsewhere are duplicated into an accessible label or hint. **Defect:** tooltips are pointer-triggered and cannot be dismissed with Esc while shown. |
| **2.4.5 Multiple Ways** | Not Applicable | Desktop application, not a set of web pages. Most destinations are reachable by menu, shortcut and the ⌘K palette. |
| **2.4.6 Headings and Labels** | Supports | Headings describe their section and labels describe their control. All-caps visual headings are spoken in natural case. |
| **2.4.7 Focus Visible** | Partially Supports | Custom controls draw the Studio focus ring (a 3 pt accent halo): buttons, rail items, segments, switches, radio buttons, tiles and cards, menu rows. In the queue, the row or card the arrow keys are on draws the ring while the queue has focus, on top of the selection tint; the settings sidebar's selected pane draws it while the sidebar has focus; the weekly grid draws it around its cursor cell; an open menu shows its highlighted item. **Defect:** not verified on hardware; custom buttons only take focus with macOS *Keyboard navigation* on. |
| **3.1.2 Language of Parts** | Not Applicable | Single language per run. |
| **3.2.3 Consistent Navigation** | Supports | The icon rail, header, status bar and detail panel keep the same position and behaviour throughout. |
| **3.2.4 Consistent Identification** | Supports | The same action carries the same name everywhere; the row state button's name comes from the same branch that chooses its glyph. |
| **3.3.3 Error Suggestion** | Supports | Failures state a remedy where one exists (failure advice on download errors, SFTP connection causes, host-key reset, missing ffmpeg). |
| **3.3.4 Error Prevention (Legal, Financial, Data)** | Partially Supports | Irreversible actions (moving files to the Trash, deleting a saved login, regenerating the API token, resetting a pinned host key) are confirmed first. Return never confirms a destructive action: Cancel holds Return and the destructive button needs a deliberate click. Removing a download from the list *without* its files is undoable through Edit ▸ Undo (⌘Z) instead of confirmed. **Defect:** the undo path has not been verified with a screen reader on hardware. |
| **4.1.3 Status Messages** | Partially Supports | Toasts, persistence warnings and similar messages are posted to the platform announcement channel. Moving the queue selection with the keyboard announces the row it lands on (and the count when several are selected); moving the weekly grid's cursor announces the hour and its profile; the confirmation dialog announces itself. **Defect:** not every asynchronous result is announced — for example the SFTP connection-test result and the media-format picker's load outcome appear without an announcement. |

---

## Table 3 — Revised Section 508, Chapter 3 (Functional Performance Criteria)

| Criterion | Conformance | Remarks |
|---|---|---|
| **302.1 Without Vision** | Partially Supports | Controls have names, composite rows read as single items, progress is spoken, keyboard moves in the queue are announced, menus and the schedule grid are keyboard and VoiceOver operable. Not confirmed with a screen reader on hardware. The Drop Basket needs a pointer (alternatives exist). |
| **302.2 With Limited Vision** | Partially Supports | Text scales with the text-size setting; Increase Contrast raises every token. Residual: tertiary, warning and success text below 4.5:1 in Light without Increase Contrast; unverified reflow at the largest sizes. |
| **302.3 Without Perception of Color** | Partially Supports | Status, server state and schedule profiles have non-colour equivalents. Residual: individual piece-map blocks. |
| **302.4 Without Hearing** | Supports | No information is conveyed by sound. |
| **302.5 With Limited Hearing** | Supports | As 302.4. |
| **302.6 Without Speech** | Supports | No speech input is required. |
| **302.7 With Limited Manipulation** | Partially Supports | Keyboard paths exist for the primary workflows. Small controls (file-tree disclosure and checkbox, copy buttons, small segments, switches, chip clear buttons) take clicks over at least 24 × 24 pt, a file row's name toggles its checkbox, and a switch row's title flips the switch. Drag-and-drop is a convenience; the Drop Basket is drag-only. |
| **302.8 With Limited Reach and Strength** | Supports | No sustained or simultaneous physical action is required. |
| **302.9 With Limited Language, Cognitive, and Learning Abilities** | Partially Supports | Plain-language error messages with remedies, a first-run walkthrough, per-setting explanations, a searchable settings window and command palette. No reading-level testing was performed. |

---

## Table 4 — Revised Section 508, Chapter 5 (Software)

| Criterion | Conformance | Remarks |
|---|---|---|
| **502.2.1 User Control of Accessibility Features** | Supports | The application does not disrupt platform accessibility features. |
| **502.2.2 No Disruption of Accessibility Features** | Supports | As above. |
| **502.3 Accessibility Services** | Partially Supports | Built on SwiftUI and exposed through the platform accessibility API: names, roles, values, states, adjustable controls and custom actions (for example *Edit server* and *Reconnect* on server rows; *Paint Hour* on the schedule grid). Not verified in the live accessibility tree. |
| **502.4 Platform Accessibility Features** | Supports | Honours the text-size setting (see 1.4.4 for what is unverified), Increase Contrast, Reduce Motion, Differentiate without colour (server status), the system caption appearance for played media, and the system light/dark appearance. |
| **503.2 User Preferences** | Supports | Follows the system appearance by default; Light and Dark are explicit choices on top, and Increase Contrast applies to both. |
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
   claim above derives from source review, unit tests and computed contrast. This
   is the single biggest limitation of this report.
2. **Light-appearance text contrast** — without Increase Contrast, tertiary text
   measures 3.92–4.26:1, warning text 3.78:1 and success text 4.39:1, below
   4.5:1. Dark and Increase Contrast clear it.
3. **Control borders** measure about 1.5:1 without Increase Contrast; controls are
   identified by fill and text rather than by their outline.
4. **Unmeasured colours** — the protocol badge, tinted chips and file-type
   artwork have not been measured against the Studio palette.
5. **Drop Basket is pointer-only.** Equivalent outcomes are reachable with ⌘N,
   ⇧⌘V and ⌘K.
6. **Piece-map blocks** are individually distinguished by colour alone; the map
   speaks its aggregate distribution rather than per-block state.
7. **Not every asynchronous result is announced** — notably the SFTP
   connection-test outcome and the media-format load outcome.
8. **Large text is unverified on hardware** — whether scaled type follows the
   macOS Text size setting, and how layouts reflow at the largest sizes.
9. **Removing a download from the list is undoable rather than confirmed**
   (see 3.3.4); moving its files to the Trash is still confirmed.

## Planned remediation

In the order a procurement reviewer is likely to care about them:

1. A recorded VoiceOver and keyboard-only pass over the primary workflows, and
   an update to this document with what it finds. This converts most
   "Partially Supports" entries into a tested answer either way.
2. Darken the Light `ink3`, `warn` and `good` tokens to clear 4.5:1 as text, and
   measure the badges and chips.
3. Announce asynchronous results that appear without taking focus.
4. Add a keyboard route into the Drop Basket, or document it as a pointer-only
   convenience in the user documentation.
5. Verify text scaling against the macOS Text size setting and test reflow at
   the largest sizes.

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
