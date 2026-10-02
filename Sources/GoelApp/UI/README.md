# Goel° UI — Studio

The Mac app's interface, in the **Studio** design. Everything a window draws lives under
`Sources/GoelApp/UI/`; the logic it presents (`TaskDisplay`, `ListPresentation`,
`QueueOverview`, `FailureAdvice`, `AppViewModel+…`) stays in `Sources/GoelApp/` and is reused,
not re-derived, by the views.

## Layout

```
Sources/GoelApp/UI/
  DesignSystem/      tokens (palette, type, metrics, OKLCH), fonts, appearance, window helpers
    Components/      the Studio… views and styles
  Kit/               app-wide helpers: accessibility (A11y, labels, a11y modifiers,
                     ShortcutHint), Dropdown, FileNameText, FilePicker, .scaledFont
  MainWindow/        window shell (RootView), icon rail, header, omnibox, status bar, toasts
  Downloads/         board, list, cards, rows, menus
  Detail/            detail sheet and bottom dock, tabs, failure / recovery sheets
  AddFlow/           add sheet: input, confirm, media formats, playlist, review, link grabber
  Settings/          settings window and panes
  SFTP/              server browser, info panel, connection editor, transfers
  Windows/           menu bar extra, history, palette, onboarding, RSS, player, stats, …
  Snapshots/         DEBUG-only snapshot harness and sample data
```

Fonts: `Sources/GoelApp/Resources/Fonts/` — Bricolage Grotesque, Figtree, Spline Sans Mono
(variable TTF + OFL licence each).

## Design system

Tokens are in the `Studio` namespace, components are `Studio…` types. Every component has a
doc comment with a usage example; those examples write bare string literals, real code passes
`L10n.t("…")`.

### Colour — `Studio.Palette.*`

Dynamic: each resolves from the drawing appearance (light / dark / Increase Contrast light /
Increase Contrast dark). Never hard-code a colour, never use `Color.primary`/`.secondary`.

| Token | Use |
|---|---|
| `canvas` | window background (sage near-white / green-ink, never black) |
| `rail` | icon rail, settings sidebar, recessed chrome |
| `card`, `well`, `cardRaised`, `sheet` | card · inset well / footer / status bar · popover & menu · sheets |
| `cardEdge`, `hairline`, `hairlineStrong` | card rim · row dividers · control borders |
| `field`, `segment`, `track` | text-field fill · segmented track & neutral pills · progress track |
| `ink`, `ink2`, `ink3`, `inverseInk` | primary · secondary · tertiary/placeholder text · text on `ink` |
| `accent`, `accentStrong`, `onAccent`, `accentSoft`, `accentLine`, `focusRing` | teal-green accent family |
| `good(+Soft)`, `warn(+Soft)`, `bad(+Soft)`, `info(+Soft)`, `upload(+Soft)` | semantic; `upload` = seeding/↑ |
| `scrim`, `glass`, `artHighlight`, `artInk` | overlays, glass badges, artwork pattern & glyph |
| `Studio.Palette.fileTint(.video)` → `.fill .fillDeep .glyph .ink .soft` | per file type |

`Studio.Tones.*` holds the same tokens as `StudioColorToken` (OKLCH values, `.nsColor`,
`.resolve(variant)`) for AppKit code and tests. `OKLCH(0.52, 0.11, 170)` converts like CSS.

### Type — `.studioFont(_:)`

```swift
Text(task.name).studioFont(.cardTitle)
Text("62").studioFont(.bigNumber)                 // display, tabular
Text(speed).studioMono()                          // Spline Sans Mono, tabular, 11.5
Text(title).studioFont(.display, size: 28, weight: 700)
StudioFonts.nsFont(.ui, size: 13, weight: 600)    // AppKit
```

Styles (`Studio.TextStyle`): `hero bigNumber title1 title2 title3 lane stat arcLabel wordmark`
(Bricolage Grotesque) · `omnibox headline cardTitle body bodyStrong control callout small caption
tiny eyebrow` (Figtree) · `mono monoSmall monoBody monoLarge badge keyCap` (Spline Sans Mono).
Modify with `.weight(650)`, `.size(12)`, `.tabular`. Weights are numeric (CSS-style, 300–800)
and set on the variable font's `wght` axis, so 650/750 really render. Everything scales with
the text-size setting through the same `@ScaledMetric` factor `.scaledFont(size:)` uses. If a
font failed to register, the system font is used. **Do not use `.font(.system(size:))`**
(`FontScalingDriftTests` fails). For the rare system-font glyph with no Studio style, use
`.scaledFont(size:weight:)` (`UI/Kit/ScaledFont.swift`), which scales by the same factor.
Use `StudioScaled { factor in … }` to scale a layout metric with the text size.

### Spacing, radius, elevation, motion

- `Studio.Space`: `hair 2 · xxs 4 · xs 6 · s 8 · sm 10 · m 12 · ml 14 · l 16 · xl 20 · xxl 28 · xxxl 32`, plus `laneGap 18`, `cardGap 10`, `gutter 22`.
- `Studio.Radius`: `badge 6 · small 8 · artSmall 9 · control 10 · segment 11 · well 12 · tile 13 · compactCard 15 · card 16 · boardCard 18 · artLarge 18 · omnibox 20 · sheet 22`.
- `.studioElevation(.flat | .raised | .card | .floating)` — layered soft shadows (`--sh-1`, `--sh-card`, `--sh-float`); apply to the background **shape**, not to text.
- `.studioSurface(.card | .well | .raised | .sheet, radius:, elevation:, isSelected:)` — fill + rim + shadow (+ dark top highlight, + 2 pt accent ring when selected). Clips content, not the shadow.
- `Studio.Motion.sweep / .quick / .spring`. Respect Reduce Motion (`@Environment(\.accessibilityReduceMotion)`) and `@Environment(\.studioStillFrames)` (set by the snapshot harness): no animation when either is true.

### Components

| Component | Example |
|---|---|
| `StudioCard` | `StudioCard { … }` · `StudioCard(padding: 0, radius: Studio.Radius.boardCard, isSelected: sel) { … }` |
| `StudioWell`, `StudioDivider`, `StudioNote`, `StudioStatTile` | `StudioNote(tone: .warn, symbol: "exclamationmark.triangle", message: …)` · `StudioStatTile(value: "1.82", unit: "TB", caption: …)` |
| `StudioFileArtwork` | `StudioFileArtwork(kind: StudioArtKind(task: task), size: .s, isFaded: paused, isFetchingMetadata: fetching)`; sizes `.xs .s .m .l` (24/32/44/64); `isGhost` placeholder; `accessibilityLabel:` to make it an element |
| `StudioArtworkBand` | `StudioArtworkBand(kind: kind) { StudioKindBadge(kind: task.kind, style: .glass) }` — 66 pt band atop a board card |
| `StudioArtKind` | `video audio image disc archive app doc magnet folder other`; `init(FileType)`, `init(task:)` (uses `DownloadTask.fileType`) |
| `StudioProgressArc` | `StudioProgressArc(fraction: 0.62)` (number inside) · `fraction: nil` spinner · `StudioProgressArc(fraction: f, diameter: 86) { Image(…) }` · `tone: StudioProgressTone(task: task)` |
| `StudioLinearProgress` | `StudioLinearProgress(fraction: f, tone: .paused, height: StudioLinearProgress.thinHeight)`; `nil` = indeterminate |
| `StudioDownloadState` | `StudioDownloadState(task:)` → `queued requestingMetadata downloading verifying paused seeding completed failed fileMissing`, with `.title .tone .symbol` |
| `StudioStatusChip` | `StudioStatusChip(state: StudioDownloadState(task: task), detail: "Seeding 1.20×")` |
| `StudioPill`, `StudioBadge`, `StudioKindBadge`, `StudioTagLabel` | `StudioPill(L10n.t("Matches"), tone: .accent)` · `StudioKindBadge(kind: .torrent)` (labels from `DownloadKind.badgeLabel`, spoken `accessibilityName`) |
| `StudioKeyCaps` | `StudioKeyCaps("⌘K")` · `StudioKeyCaps(keys: ["⇧", "⌘", "T"])` |
| Buttons | `.buttonStyle(.studio(.primary / .secondary / .soft / .ghost / .destructive / .destructivePrimary, size: .small/.regular/.large, fullWidth:))` — use `Button(title, systemImage:)` for icon+label |
| `StudioIconButton` | `StudioIconButton("xmark", label: L10n.t("Close"), size: .small, bordered:, isOn:, shortcutHint: "⌘I") { … }` — label = tooltip + VoiceOver |
| `StudioPillButtonStyle` | `.buttonStyle(StudioPillButtonStyle(isOn: on))` |
| `StudioChip`, `StudioFilterChip` | `StudioFilterChip(L10n.t("Active"), count: 4, isOn: filter == .active) { … }` |
| `StudioSegmentedControl` | `StudioSegmentedControl(selection: $layout, segments: [StudioSegment(.board, title: …, symbol: …, help: …)], size:, fullWidth:)` — per segment: `help` (its own tooltip), `accessibilityValue`, `isEnabled`, `actions: [StudioSegmentAction(title:) { … }]` (context menu + VoiceOver actions) |
| `StudioTabBar` | `StudioTabBar(selection: $tab, tabs: DetailTab.allCases.map { StudioSegment($0, title: $0.title) })` |
| `StudioOmnibox`, `StudioOmniboxSuggestion` | `StudioOmnibox(text: $q, placeholder: …, isFocused: $focus, onSubmit: go) { StudioOmniboxSuggestion { … } }` |
| `StudioSearchField`, `.textFieldStyle(.studio)`, `StudioFocusedField`, `StudioFieldChrome` | `TextField(…).textFieldStyle(.studio(size: .small))` |
| `StudioSectionHeader` | `StudioSectionHeader(L10n.t("Recent throughput"), detail: "peak 14.2 MB/s")` |
| `StudioFormCard`, `StudioFormRow`, `StudioToggleRow` | `StudioFormCard(title:, symbol:, footer:) { StudioToggleRow(L10n.t("…"), subtitle:, isOn: $x); StudioFormRow(L10n.t("…")) { control } }` |
| Toggle styles | `.toggleStyle(.studioSwitch)` · `.toggleStyle(.studioCheckbox)` (mixed state supported) |
| `StudioSheet`, `StudioSheetFooter` | `StudioSheet(title:, subtitle:, symbol:, onClose:) { … } footer: { StudioSheetFooter(onCancel: dismiss, primaryTitle: …, primaryRole: .destructive, onPrimary: go) }` — Esc = Cancel/close, ↩ and ⌘↩ = primary |
| `StudioPopover`, `StudioMenuRow` | `.popover { StudioPopover(title: …) { StudioMenuRow(symbol:, title:, shortcut:, isChecked:) { … } } }` |
| `StudioEmptyState` | `StudioEmptyState(symbol: "tray", title: …, message: …) { buttons }` |
| `StudioToastCard` | `StudioToastCard(tone: .good, symbol: "checkmark", title: …, actionTitle: L10n.t("Undo"), onAction:, onDismiss:)` |
| `StudioLegendItem` | `StudioLegendItem(L10n.t("Downloaded"), color: Studio.Palette.accent)` — chart legend swatch + caption, decorative |
| `StudioSparkline` / `StudioAreaChart` | `StudioSparkline(values: down, secondary: up, gridLines: 2, showsEndDot: true).frame(height: 60)` |
| `StudioRailItem`, `StudioRailBadge`, `StudioRailSeparator` | `StudioRailItem(symbol:, title:, badge: 4, isSelected:, isExpanded:, count:, shortcut: "⌘1") { … }` |
| `StudioLaneHeader` | `StudioLaneHeader(title: L10n.t("Downloading"), count: 4, detail: "↓ 43 MB/s", detailIsMono: true)` |
| `StudioWordmark` | the Goel° wordmark |
| `.studioFocusRing(isFocused, shape:)` | the 3 pt accent halo for custom focusable controls; read `isFocused` in a `ButtonStyle` body, never in the view that builds the `Button` (that reports its ancestor) |
| `.studioPlain`, `.studioButtonFocusRing(shape:)` | a hand-drawn button: `Button { tile.studioButtonFocusRing(shape: s) }.buttonStyle(.studioPlain)`; `.studioHitOutset(_:)` grows a small control's click target to 24 pt without moving it |

Icons are SF Symbols; the mockup's icon names map to: board `rectangle.3.group`, list
`list.bullet`, history `clock.arrow.circlepath`, server `server.rack`, rss
`dot.radiowaves.up.forward`, convert `arrow.left.arrow.right`, tag `tag`, chart `chart.bar`,
basket `basket`, settings `slider.horizontal.3`, gauge `gauge.with.dots.needle.33percent`,
snail `tortoise`, inbox `tray`, retry `arrow.clockwise`, sidebar `sidebar.left`. There is no
SF magnet: use `StudioMagnetShape()` (stroked) or `StudioArtGlyph(kind: .magnet, size:)`.

### Windows, materials, appearance

- Root of every window: `.studioWindowBackground()` (canvas behind everything, `NSWindow.backgroundColor` set, title bar blended). AppKit panels: `window.applyStudioChrome(appearance: mode)`.
- `.studioRailBackground()`, `.studioGlass(in: shape)` (controls over artwork/video), `.studioScrim()`.
- Appearance: `StudioAppearanceMode` = `.system / .light / .dark` (`title`, `symbol`, `colorScheme`, `nsAppearance`). Read/write `viewModel.appearanceMode`; ⇧⌘T calls `viewModel.toggleAppearanceMode()`. Scenes use `appearance.colorScheme` / `.mode` (`AppAppearance`).
- Storage is `AppSettings.theme` (GoelCore). Values from the old palette picker migrate on read — `frost-light`/`light` → Light; `frost-dark`/`dracula`/`nord`/`dark` → Dark; `system` and anything unknown → System — and are never rewritten behind the user's back. New writes are `system`/`light`/`dark`. The web portal's look is separate: `AppSettings.remoteTheme`, read through `RemotePortalTheme` (Match the device / Light / Dark).


## Snapshot harness

```sh
GOEL_BREW_PREFIX="$PWD/Vendor/macos/arm64" swift build --product GoelDownloader
.build/debug/GoelDownloader --studio-snapshots /tmp/studio --only downloads.   # one area
.build/debug/GoelDownloader --studio-snapshots /tmp/studio --only ds.          # the gallery
```

Writes `<name>-light.png` and `<name>-dark.png` per entry (sRGB, 2× by default; `--scale 1`
for smaller files), prints each path, exits non-zero on failure. Look at both PNGs after any visual change. Rendering uses an offscreen `NSWindow` + `NSHostingView`
+ `cacheDisplay` (AppKit-backed controls render; `ImageRenderer` would blank them), with the
window's appearance set per pass, and `\.studioStillFrames = true` so animations show a still
frame. DEBUG builds only (`#if DEBUG`); the process gets `.prohibited` activation, no Dock
icon, no engine, no database, no settings writes.

Register entries in the area's file (`UI/Snapshots/<Area>Snapshots.swift`); `SnapshotRegistry`
collects them all:

```swift
#if DEBUG
@MainActor
enum DownloadsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.board", width: 1280, height: 860) { context in
                DownloadListView().studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("downloads.note", width: 320) { _ in   // height: nil = fit
                StudioNote(tone: .warn, symbol: "exclamationmark.triangle", message: "Low disk space")
                    .padding(20)
            },
        ]
    }
}
#endif
```

Names must start with the area prefix: `main.` `downloads.` `detail.` `add.` `settings.`
`sftp.` `windows.` (a test enforces this and uniqueness). Keep any preview-only helper views
inside `#if DEBUG`.

### Sample data

`StudioSampleData` (`UI/Snapshots/SampleData.swift`, DEBUG):

- `StudioSampleData.tasks` — 11 `DownloadTask`s: ubuntu ISO (HTTP, 4.7 GB, 62 %, 12 MB/s, 8 connections), debian DVD (BT, seeding, ratio 1.20), Cosmos .mkv (BT, 17 GB, 41 %, 3 files, trackers, piece map), project-backup .tar.zst (SFTP, 78 %), a magnet fetching metadata, imagenet .zip (HTTP, paused 34 %), BigBuckBunny .mp4 (HLS, completed), Fedora ISO (FTP, failed "FTP server closed the connection"), Field Recordings .flac and Figma .dmg (queued #2/#3), Q3-board-pack.pdf (completed).
- `StudioSampleData.task(.cosmos)` / `context.task(.cosmos)`; stable IDs via `StudioSampleData.ID.x.uuid`.
- `StudioSampleData.makeViewModel(selecting: .ubuntu)` / `context.model` — a real `AppViewModel` showing them (selection set, `isRestoring == false`, a minute of speed history in `telemetry`). `.studioSampleEnvironment(model)` injects it plus `telemetry` and `sftpStore` as environment objects, exactly as the scenes do.

How the sample model is built: `AppViewModel` has a designated
`init(system:opened:manager:settings:)`; the production `init(system:)` is a convenience init
that opens the real database and builds the real `DownloadManager`, unchanged. The sample
passes an in-memory `PersistenceStore()`, a `DownloadManager` whose five engines are inert
stubs and whose power/folder-watch/scanner/credential ports are no-ops, and never calls
`start()`. A DEBUG-only `installSampleSnapshot(_:selecting:)` (in `AppViewModel.swift`) sets
`tasks` and recomputes the list without the live path's side effects (no notification handlers,
Dock/Finder progress, banners). Actions you trigger in a snapshot reach the inert manager and
go nowhere. Area-specific sample state lives beside it in `UI/Snapshots/`, built from public
model types: `SFTPSampleFixture` (the one set of servers, a remote folder and transfers — other
areas take subsets, e.g. `activeTransfers()`), `WindowsSampleData` (conversion jobs, stats,
history rows, RSS) and `AddFlowSnapshotSamples`. `StudioSampleData.gb` / `.mb` / `.downloads`
are the shared units and folder.

Known renderer artefact: `cacheDisplay` draws a plain-style `TextField`'s placeholder in the
label colour, so placeholders look like real text in snapshots. On screen they draw in the
system placeholder grey; this is not a styling bug.

## Rules

- **L10n:** every user-facing string is `L10n.t("English text")` (the key is the English);
  formats use `%@`/`%d`/`%1$@`. After adding keys run `python3 Scripts/extract-l10n-keys.py`
  (`LocalizationTests` fails otherwise). Snapshot-only text uses `Text(verbatim:)`.
- **No `Bundle.module`** (build_app.sh rejects it). Resources come from `ResourceBundles.app`.
- **Accessibility:** every icon-only control has a label (`StudioIconButton` requires one);
  use the `A11y.*` helpers and `a11yGroup` / `a11yButton` / `a11yDecorative`.
- **File names:** show them with `FileNameText(name, lineLimit:)` — it breaks at `.` `-` `_`
  instead of mid-word, truncates in the middle and keeps the full name in the tooltip and
  the accessibility label. Its text carries invisible break characters, so don't make it
  selectable.
- **Snapshots are DEBUG-only:** every entry and preview helper sits in `#if DEBUG`.
- **No `.font(.system(size:))`**; colours only from `Studio.Palette`; sizes from `Studio.Space` /
  `Studio.Radius` unless the mockup says otherwise.
- `swift build` stays warning-free and `swift test` green.
