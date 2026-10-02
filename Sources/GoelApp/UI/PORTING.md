# Studio porting guide

The Goel° UI is being rewritten from scratch in the **Studio** design direction. The visual spec
is the Studio HTML mockup (28 artboards: board, rows, detail tabs, add flow, settings, SFTP, RSS,
player, overlays, portal). This file is for the agents that rewrite one area each, in parallel,
in separate worktrees. Read it before you touch anything.

What already exists (the foundation, on `feat/studio-redesign`):

```
Sources/GoelApp/UI/
  DesignSystem/            tokens, fonts, appearance, window helpers   (shared, do not fork)
    Components/            Studio… views and styles                    (shared, do not fork)
  Snapshots/               DEBUG-only snapshot harness + sample data
    SnapshotRegistry.swift   collects every area's entries             (do not edit)
    SnapshotRenderer.swift   the --studio-snapshots command            (do not edit)
    SampleData.swift         the 11 sample downloads + sample AppViewModel
    DesignSystemSnapshots.swift  the gallery (ds.*)
    <Area>Snapshots.swift    one per area, empty — yours to fill
  PORTING.md               this file
Resources/Fonts/           Bricolage Grotesque, Figtree, Spline Sans Mono (variable TTF + OFL)
```

Put your new views in `Sources/GoelApp/UI/<Area>/` (`MainWindow`, `Downloads`, `Detail`,
`AddFlow`, `Settings`, `SFTP`, `Windows`). Never edit another area's folder or another area's
snapshot file. If the design system lacks something, build it inside your area first (named
`Studio…` but in your folder) and say so in your report; it is promoted at integration.

---

## 1. Design system cheat sheet

Everything is in the `Studio` namespace (tokens) or a `Studio…` type (components), so nothing
clashes with the old `Theme`, `KindBadge`, `EmptyStateView`, `SheetHeader`…

Every component has a doc comment with a usage example. Doc-comment examples write bare string
literals (the key extractor would otherwise harvest them); real code passes `L10n.t("…")`.

### Colour — `Studio.Palette.*`

Dynamic: each resolves from the drawing appearance (light / dark / Increase Contrast light /
Increase Contrast dark). Never hard-code a colour, never use `Color.primary`/`.secondary` in new UI.

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
(`FontScalingDriftTests` fails) — and prefer `.studioFont` over the old `.scaledFont`.
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
| `StudioSegmentedControl` | `StudioSegmentedControl(selection: $layout, segments: [StudioSegment(.board, title: …, symbol: …)], size:, fullWidth:)` |
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
| `StudioSparkline` / `StudioAreaChart` | `StudioSparkline(values: down, secondary: up, gridLines: 2, showsEndDot: true).frame(height: 60)` |
| `StudioRailItem`, `StudioRailBadge`, `StudioRailSeparator` | `StudioRailItem(symbol:, title:, badge: 4, isSelected:, isExpanded:, count:, shortcut: "⌘1") { … }` |
| `StudioLaneHeader` | `StudioLaneHeader(title: L10n.t("Downloading"), count: 4, detail: "↓ 43 MB/s", detailIsMono: true)` |
| `StudioWordmark` | the Goel° wordmark |
| `.studioFocusRing(isFocused, shape:)` | the 3 pt accent halo for custom focusable controls |

Icons are SF Symbols; the mockup's icon names map to: board `rectangle.3.group`, list
`list.bullet`, history `clock.arrow.circlepath`, server `server.rack`, rss
`dot.radiowaves.up.forward`, convert `arrow.left.arrow.right`, tag `tag`, chart `chart.bar`,
basket `basket`, settings `slider.horizontal.3`, gauge `gauge.with.dots.needle.33percent`,
snail `tortoise`, inbox `tray`, retry `arrow.clockwise`, sidebar `sidebar.left`. There is no
SF magnet: use `StudioMagnetShape()` (stroked) or `StudioArtGlyph(kind: .magnet, size:)`.

### Windows, materials, appearance

- Root of every new window: `.studioWindowBackground()` (canvas behind everything, `NSWindow.backgroundColor` set, title bar blended). AppKit panels: `window.applyStudioChrome(appearance: mode)`.
- `.studioRailBackground()`, `.studioGlass(in: shape)` (controls over artwork/video), `.studioScrim()`.
- Appearance: `StudioAppearanceMode` = `.system / .light / .dark` (`title`, `symbol`, `colorScheme`, `nsAppearance`). Read/write `viewModel.appearanceMode`; ⇧⌘T calls `viewModel.toggleAppearanceMode()`. Scenes keep using `appearance.colorScheme` (`AppAppearance`, now also publishing `.mode`). The Settings picker should offer exactly these three.
- Storage is unchanged: `AppSettings.theme` (GoelCore). Old values migrate on read — `frost-light`/`light` → Light; `frost-dark`/`dracula`/`nord`/`dark` → Dark; `system` and anything unknown → System. New writes are `system`/`light`/`dark`, which the old `AppTheme(settingsValue:)` already accepted, so old views and older builds keep working. Fresh installs now default to `system` (was `frost-dark`). The web portal's `remoteTheme` is separate and untouched. Behaviour change: a stored `system` used to force the dark Frost palette; it now follows the Mac.

---

## 2. Snapshot harness (you can't see the screen — use this)

```sh
GOEL_BREW_PREFIX="$PWD/Vendor/macos/arm64" swift build --product GoelDownloader
.build/debug/GoelDownloader --studio-snapshots /tmp/studio --only downloads.   # your area
.build/debug/GoelDownloader --studio-snapshots /tmp/studio --only ds.          # the gallery
```

Writes `<name>-light.png` and `<name>-dark.png` per entry (sRGB, 2× by default; `--scale 1`
for smaller files), prints each path, exits non-zero on failure. Then **look at both PNGs with
the Read tool** and fix what looks off. Rendering uses an offscreen `NSWindow` + `NSHostingView`
+ `cacheDisplay` (AppKit-backed controls render; `ImageRenderer` would blank them), with the
window's appearance set per pass, and `\.studioStillFrames = true` so animations show a still
frame. DEBUG builds only (`#if DEBUG`); the process gets `.prohibited` activation, no Dock
icon, no engine, no database, no settings writes.

Register entries in **your** file only (`UI/Snapshots/<Area>Snapshots.swift`):

```swift
#if DEBUG
@MainActor
enum DownloadsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.board", width: 1280, height: 860) { context in
                DownloadsBoard().studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("downloads.card.failed", width: 300) { context in   // height: nil = fit
                DownloadCard(task: context.task(.fedora)).padding(20)
            },
        ]
    }
}
#endif
```

Names must start with your area prefix: `main.` `downloads.` `detail.` `add.` `settings.`
`sftp.` `windows.` (a test enforces this and uniqueness). Keep any preview-only helper views
inside `#if DEBUG`.

### Sample data

`StudioSampleData` (`UI/Snapshots/SampleData.swift`, DEBUG):

- `StudioSampleData.tasks` — 11 `DownloadTask`s: ubuntu ISO (HTTP, 4.7 GB, 62 %, 12 MB/s, 8 connections), debian DVD (BT, seeding, ratio 1.20), Cosmos .mkv (BT, 17 GB, 41 %, 3 files, trackers, piece map), project-backup .tar.zst (SFTP, 78 %), a magnet fetching metadata, imagenet .zip (HTTP, paused 34 %), BigBuckBunny .mp4 (HLS, completed), Fedora ISO (FTP, failed "FTP server closed the connection"), Field Recordings .flac and Figma .dmg (queued #2/#3), Q3-board-pack.pdf (completed).
- `StudioSampleData.task(.cosmos)` / `context.task(.cosmos)`; stable IDs via `StudioSampleData.ID.x.uuid`.
- `StudioSampleData.makeViewModel(selecting: .ubuntu)` / `context.model` — a real `AppViewModel` showing them (selection set, `isRestoring == false`, a minute of speed history in `telemetry`). `.studioSampleEnvironment(model)` injects it plus `telemetry` and `sftpStore` as environment objects, exactly as the scenes do.

How it is built (the seam): `AppViewModel` now has a designated
`init(system:opened:manager:settings:)`; the production `init(system:)` is a convenience init
that opens the real database and builds the real `DownloadManager`, unchanged. The sample
passes an in-memory `PersistenceStore()`, a `DownloadManager` whose five engines are inert
stubs and whose power/folder-watch/scanner/credential ports are no-ops, and never calls
`start()`. A DEBUG-only `installSampleSnapshot(_:selecting:)` (in `AppViewModel.swift`) sets
`tasks` and recomputes the list without the live path's side effects (no notification handlers,
Dock/Finder progress, banners). Actions you trigger in a snapshot reach the inert manager and
go nowhere. If your area needs more sample state (SFTP servers, RSS feeds, history rows), build
it in your snapshot file from public model types; don't edit `SampleData.swift` (shared).

---

## 3. Rules

- **L10n:** every user-facing string is `L10n.t("English text")` (the key is the English).
  Formats use `%@`/`%d`/`%1$@`. Do **not** commit `Localizable.strings`; the table is
  regenerated at integration (`python3 Scripts/extract-l10n-keys.py`). Snapshot/gallery-only
  text uses `Text(verbatim:)`.
- **No `Bundle.module`** anywhere (build_app.sh rejects it). Resources: `ResourceBundles.app`.
- **Keep accessibility labels**: every icon-only control has a label (`StudioIconButton` forces
  one); keep the old view's `accessibilityLabel`/`Value`/`Hint` text and the `A11y.*` helpers.
- **Keep every keyboard shortcut** the old views define (`.keyboardShortcut`, `onKeyPress`,
  menu commands, `.onExitCommand`, `.onDeleteCommand`, `.onMoveCommand`) — grep your old files.
- **Snapshots are DEBUG-only**: every snapshot entry and preview helper sits in `#if DEBUG`.
- **Don't delete old files** owned by another area. Old files of your own area may only be
  deleted when nothing outside your area references their symbols (see §5) — otherwise leave
  the symbol in place (or provide it from your new code with the same name and signature).
- **Design system is shared**: don't edit `UI/DesignSystem/**`, `SnapshotRegistry.swift`,
  `SnapshotRenderer.swift`, `SampleData.swift` or `Theme.swift`. Prefix new shared-looking
  helpers with your area if they live in your folder.
- **No `.font(.system(size:))`**; colours only from `Studio.Palette`; sizes from `Studio.Space` /
  `Studio.Radius` unless the mockup says otherwise.
- `swift build` must stay warning-free in your files, and `swift test` green, before you hand back.

### What the design system itself uses from the old code (keep these alive)

| Symbol | Defined in | Owner |
|---|---|---|
| `A11y.percent`, `A11y.speed` | Views/AccessibilitySupport.swift | MainWindow |
| `ShortcutHint.help` | Views/AccessibilitySupport.swift | MainWindow |
| `FileType.accessibilityName`, `DownloadKind.accessibilityName` | Views/AccessibilitySupport.swift | MainWindow |
| `DownloadKind.badgeLabel`, `DownloadTask.fileType`, `.isFileMissing`, `.compactDisplayName`, `.statusCompactText`, `.statusDetailText`, `.compactSizeLine` | TaskDisplay.swift (logic) | shared |
| `FileType`, `FileType.classify` | FileTypeClassification.swift (logic; moved out of Theme.swift) | shared |
| `AppearanceVariant`, `IncreaseContrast`, `WCAG` | UI/DesignSystem/StudioAppearanceVariant.swift (moved out of Theme.swift) | design system |
| `AppAppearance` | UI/DesignSystem/StudioAppearance.swift (moved out of Theme.swift) | design system |

`AccessibilitySupport.swift` and `ThemeTokens.swift` are foundation files used by all seven
areas and by logic files (`DiskSpaceCheck`, `SpeedProfileText`, `ToastQueue`, `ListPresentation`,
`SidebarCatalog`, `AppViewModel+Selection`). MainWindow owns them but must not delete or rename
anything in them during the rewrite; they are relocated at integration. `Theme.swift` (old
palette, `Theme.*`, `AppTheme`, `ThemePalette`, `IconFill`, `FileTileCache`,
`DetailPanelPosition`) is deleted at the end, after every area has moved off it —
`DetailPanelPosition` and `AppViewModel.theme`/`remoteTheme` need a new home then.

## 4. Area ownership

Every file in `Sources/GoelApp/Views/` belongs to exactly one area. Your area rewrites its files' UI under `UI/<Area>/`; the old file stays until nothing else references it.

| File | Area | Note |
|---|---|---|
| AccessibilitySupport.swift | MainWindow | foundation kit used by every area; shell owner keeps it stable |
| AddDownloadSheet.swift | AddFlow | add sheet |
| AddDownloadSheetParts.swift | AddFlow | add sheet parts |
| AddOptionControls.swift | AddFlow | option controls |
| AppToolbar.swift | MainWindow | toolbar/omnibox |
| AutoShutdownCountdownView.swift | Windows | auto-shutdown |
| BrowserCards.swift | Settings | browser cards (also OnboardingPanes) |
| CappedScrollView.swift | AddFlow | only used by AddDownloadSheet |
| CommandPalette.swift | Windows | command palette, SettingsRoute, CommandPaletteBus |
| CompletedHero.swift | Detail | completed hero |
| CookieSourcePicker.swift | AddFlow | cookie picker (also FailureRecoverySheets) |
| CreateTorrentView.swift | Windows | create torrent |
| CustomControls.swift | MainWindow | ActionMenu/ToolbarMenuLabel/ConfirmDialogView are toolbar/RootView chrome; Dropdown used by AddFlow+Settings |
| DetailBottomPanel.swift | Detail | bottom-docked panel |
| DetailPanelComponents.swift | Detail | ring, graph, pills, action buttons |
| DetailPanelResizeHandle.swift | Detail | resize handle + DetailPanelHeight |
| DetailPanelView.swift | Detail | detail panel |
| DetailTabs.swift | Detail | tabs, KVRow, SectionLabel |
| DownloadListColumns.swift | Downloads | column menu/cells |
| DownloadListParts.swift | Downloads | row parts, section header, queue drop target |
| DownloadListView.swift | Downloads | list/board, DownloadRow, DownloadColumns |
| DropBasketWindow.swift | Windows | drop basket |
| EmptyStateView.swift | MainWindow | DownloadsEmptyState, hosted by RootView |
| ExtraTrackersSettings.swift | Settings | extra trackers |
| FailureCard.swift | Detail | failure card |
| FailureRecoverySheets.swift | Detail | recovery sheets |
| FileActionMenus.swift | Downloads | 3 of 4 menus used by DownloadListView (CompletedHeroMoreMenu -> Detail) |
| FileTreeView.swift | Detail | file tree |
| GlobalSpeedGraphViews.swift | Windows | global speed graphs |
| HistoryView.swift | Windows | history window + ScheduledStartOption |
| InAppPlayerView.swift | Windows | player |
| LicensePane.swift | Settings | licence |
| LinkGrabberSheet.swift | AddFlow | link grabber |
| LinkReviewView.swift | AddFlow | link review |
| MarkdownText.swift | Windows | markdown (per the brief); its only user is AddDownloadSheet (AddFlow) |
| MediaFormatPicker.swift | AddFlow | media format picker, playlist checklist |
| MediaJobDock.swift | Windows | media job dock |
| MediaPresetPicker.swift | AddFlow | media preset picker |
| MenuBarView.swift | Windows | menu bar extra + MainWindowID |
| MultiSelectionPanel.swift | Detail | multi-selection |
| OnboardingPanes.swift | Windows | onboarding panes |
| OnboardingView.swift | Windows | onboarding |
| PanelHelpers.swift | MainWindow | FilePicker + collectDroppedURLs; drop handling lives in RootView; also GoelDownloaderApp |
| PeerRow.swift | Detail | peers |
| QRCodeView.swift | Windows | QR + `LANAddress` (per the brief); only user is the Web Access pane in SettingsPanesAutomation (Settings) |
| QueueOverviewPanel.swift | Detail | queue overview |
| RootView.swift | MainWindow | window shell, drop overlay, banners, sheet routing |
| RSSReaderView.swift | Windows | RSS reader |
| RSSRuleSheet.swift | Windows | RSS rule sheet |
| RSSSidebarGroup.swift | MainWindow | only used by SidebarView |
| SettingsAggregationPane.swift | Settings | aggregation |
| SettingsControls.swift | Settings | settings controls |
| SettingsPanesAutomation.swift | Settings | panes + free func setting() |
| SettingsPanesGrouped.swift | Settings | panes |
| SettingsRuleEditor.swift | Settings | rules |
| SettingsRulesPane.swift | Settings | rules |
| SettingsSearch.swift | Settings | settings search index |
| SettingsView.swift | Settings | settings window + Pane enum |
| SFTPAllTransfersView.swift | SFTP | all transfers (sidebar row used by SidebarView) |
| SFTPBrowserSupport.swift | SFTP | file icons, QuickLookPresenter |
| SFTPBrowserView.swift | SFTP | browser |
| SFTPConnectionEditor.swift | SFTP | connection editor |
| SFTPInfoPanel.swift | SFTP | info panel |
| SFTPTransferPanel.swift | SFTP | transfer panel |
| SFTPUploadConflictSheet.swift | SFTP | upload conflict sheet |
| SharedViews.swift | Downloads | row primitives (FileTypeIcon, KindBadge, MiniProgressBar, StateButton, RowStateAction) are the list's; sheet/empty-state bits used everywhere |
| SheetFormHelpers.swift | AddFlow | sheet form helpers per brief; RemoteNameInput/SFTPConnectionForm used by SFTP |
| SidebarView.swift | MainWindow | sidebar -> rail |
| SpeedCapPopover.swift | Windows | speed cap popover |
| SpeedGraphViews.swift | Windows | statistics, sparkline |
| StatusBarView.swift | MainWindow | status bar |
| ThemeTokens.swift | MainWindow | foundation kit (Theme tokens, IconButton) used by every area |
| ToastOverlay.swift | MainWindow | toasts (also hosted by SettingsView) |
| ToolbarExtras.swift | MainWindow | toolbar extras + customize menu |
| TrackerEditing.swift | Detail | trackers sheet |
| WeeklyProfileGrid.swift | Settings | weekly grid |

Assignment decisions (shared/ambiguous files):

- AccessibilitySupport, ThemeTokens: used by all 7 areas → MainWindow as foundation owner; other areas must not edit them, only add.
- CustomControls → MainWindow: 4 of 5 types (ActionMenu, ActionMenuItem, ToolbarMenuLabel, ConfirmDialogView) are toolbar/RootView chrome; `Dropdown` is the only type AddFlow/Settings use (Settings 18 hits, AddFlow 14, MainWindow 16).
- PanelHelpers → MainWindow: no dominant view user (Windows 5, SFTP 5, Settings 4, AddFlow 3); drop handling belongs with RootView's drop overlay and GoelDownloaderApp uses `FilePicker`.
- SharedViews → Downloads: grab-bag; row primitives (FileTypeIcon, KindBadge, MiniProgressBar, StateButton, RowStateAction, IndeterminateBar) are the list's. Windows has the most hits (20, MenuBarView mirrors rows), Detail 10, Downloads 7.
- SheetFormHelpers → AddFlow per brief; SFTP uses `RemoteNameInput`/`SFTPConnectionForm` (could move to SFTP).
- CappedScrollView → AddFlow (only consumer AddDownloadSheet). MarkdownText and QRCodeView stay with Windows as the brief assigns them, although their only consumers are AddFlow (AddDownloadSheet) and Settings (Web Access pane) — see the Windows cross-reference rows.
- RSSSidebarGroup → MainWindow (only used by SidebarView). FileActionMenus → Downloads (CompletedHeroMoreMenu is used by Detail's CompletedHero).
- Drop overlay has no file of its own: it lives in RootView (MainWindow).

Files per area: MainWindow 12, Downloads 5, Detail 13, AddFlow 10, Settings 12, SFTP 7, Windows 17 (total 76).

### Shared presentation logic (not moved or rewritten by area agents)

These live in `Sources/GoelApp/` (not `Views/`). Reuse them from new code instead of re-deriving state, labels or formatting. Change them only if your area is the sole user, and keep their tests green.

Reliance = view files naming a non-private type of the file, or a distinctive (≥6 chars, non-generic) extension member; generic ext members such as `.title`/`.symbol` are not counted, so `ext` rows are a lower bound.

| File (Sources/GoelApp/) | Main types | Areas relying on it (view files) |
|---|---|---|
| AutoShutdownCountdown.swift | AutoShutdownCountdown | Windows (AutoShutdownCountdownView, MenuBarView) |
| BrowserStatus.swift | BrowserActivityLog, BrowserStatus, ext BrowserIntegrationService | Settings (BrowserCards) |
| CommandState.swift | CommandState | Windows (MenuBarView) |
| CompletionSummary.swift | CompletionSummary | Detail (CompletedHero, DetailPanelView) |
| DiskSpaceCheck.swift | DiskSpaceCheck | Detail (FailureRecoverySheets, QueueOverviewPanel); AddFlow (AddDownloadSheet, LinkReviewView); SFTP (SFTPBrowserView) |
| DisplayFormat.swift | DisplayFormat | Windows (GlobalSpeedGraphViews, MenuBarView) |
| FailureAdvice.swift | FailureAdvice | Downloads (DownloadListView); Detail (FailureCard); Windows (MenuBarView) |
| FileNameEdit.swift | FileNameEdit | AddFlow (AddDownloadSheet, AddDownloadSheetParts) |
| FileTree.swift | FileCheckState, FileSelectionPreset, FileTree, FileTreeItem, FileTreeNode | Detail (DetailTabs, FileTreeView) |
| FileTypeClassification.swift | ext FileType | none (app/VM only) |
| FocusBus.swift | FocusBus | MainWindow (AppToolbar) |
| HistoryPresentation.swift | HistoryPresentation | Windows (HistoryView) |
| InAppPlayback.swift | InAppPlayback | Downloads (DownloadListView); Detail (CompletedHero) |
| InboundDrop.swift | InboundDrop | MainWindow (RootView); AddFlow (AddDownloadSheet); Windows (DropBasketWindow) |
| LinkReview.swift | LinkReview, LinkReviewItem, RecentFolders | AddFlow (AddDownloadSheet, AddOptionControls, LinkGrabberSheet, LinkReviewView) |
| ListColumns.swift | ListColumn, ListColumnPrefs, ListDensity | Downloads (DownloadListColumns, DownloadListView); Windows (CommandPalette) |
| ListPresentation.swift | DateBucket, ListGrouping, ListPresentation, ListSection, StatusBucket | MainWindow (AppToolbar, SidebarView); Downloads (DownloadListParts); Windows (HistoryView) |
| MediaPreset.swift | MediaPreset | AddFlow (AddDownloadSheet, MediaFormatPicker, MediaPresetPicker) |
| QueueOverview.swift | QueueOverview | MainWindow (StatusBarView); Detail (MultiSelectionPanel, QueueOverviewPanel) |
| RSSReaderModel.swift | RSSReaderModel, RSSText | MainWindow (RSSSidebarGroup, RootView, SidebarView); Settings (SettingsPanesAutomation); Windows (CommandPalette, RSSReaderView, RSSRuleSheet) |
| SelectionAggregate.swift | SelectionAggregate | MainWindow (StatusBarView); Detail (MultiSelectionPanel) |
| SelectionRange.swift | SelectionRange | none (app/VM only) |
| SFTPAddressImport.swift | SFTPAddress, SSHConfigImport | SFTP (SFTPConnectionEditor) |
| SFTPServerStatus.swift | SFTPReachability, ServerMeta, ServerOS, ServerReachability | MainWindow (AccessibilitySupport, SidebarView); SFTP (SFTPTransferPanel) |
| SidebarCatalog.swift | SidebarCatalog, SidebarEntry | MainWindow (AppToolbar, SidebarView) |
| SpeedCapInput.swift | SpeedCapInput | Windows (SpeedCapPopover) |
| SpeedProfileText.swift | SpeedProfileText | MainWindow (StatusBarView); Detail (QueueOverviewPanel); Windows (MenuBarView) |
| TaskDisplay.swift | SpeedCellText, ext DownloadKind, ext DownloadTask | 14 view files: Downloads 3, Detail 6, AddFlow 1, SFTP 1, Windows 3 |
| Theme.swift | AppAppearance, AppTheme, AppearanceVariant, DetailPanelPosition, FileTileCache, FileType … | 70 view files: MainWindow 11, Downloads 4, Detail 13, AddFlow 8, Settings 12, SFTP 7, Windows 15 |
| ToastQueue.swift | Toast, ToastCountdown, ToastQueue, ext AppViewModel | 12 view files: MainWindow 1, Downloads 1, Detail 1, AddFlow 1, Settings 3, SFTP 3, Windows 2 |
| ToolbarCustomization.swift | ToolbarSlot | MainWindow (AppToolbar, ToolbarExtras) |
| WindowLayout.swift | WindowLayout | MainWindow (RootView) |

### Non-view app files that depend on Views-defined symbols

These break if the owning area renames/removes the symbol; keep them (or move them to logic) before deleting the old view file.

| App file | Views symbols used (owner area) |
|---|---|
| AppViewModel+Selection.swift | FilePriority.title (MainWindow) |
| DiskSpaceCheck.swift | A11y (MainWindow) |
| GoelDownloaderApp.swift | CommandPaletteBus (Windows), CreateTorrentWindow (Windows), DropBasketController (Windows), FilePicker (MainWindow), HistoryView (Windows), MainWindowID (Windows), MenuBarSpeedLabel (Windows), MenuBarView (Windows), PlayerWindow (Windows), RootView (MainWindow), SettingsView (Settings), SidebarFilter.accessibilityName (MainWindow) |
| LinkReview.swift | GrabbedLink (AddFlow), GrabbedLink.Category (AddFlow), LinkExtractor (AddFlow) |
| ListPresentation.swift | FileType.accessibilityName (MainWindow) |
| MainWindowPresenter.swift | MainWindowID (Windows) |
| SFTPBrowserModel.swift | SFTPEntryInfo (SFTP) |
| SidebarCatalog.swift | SidebarFilter.accessibilityName (MainWindow) |
| SpeedProfileText.swift | A11y (MainWindow) |
| ToastQueue.swift | A11yAnnouncer (MainWindow) |

## 5. Cross-area references

If you own a symbol below, keep its name and signature working (leave the old declaration, or
declare the same name from your new code) until the users listed have been rewritten. If you
*use* a symbol owned by another area from your new code, prefer the shared logic files or the
design system instead, so your area doesn't depend on code that is about to be rewritten.

Generated when this foundation was cut (commit on `feat/studio-redesign`) by a script that extracted, per file: non-private types (incl. nested, matched as `Outer.Inner`), non-private extension members (matched as `.member` / `\.member`), ext inits (matched as `Type(label:`), and free functions; comments/strings stripped. Generic member names (`title`, `accessibilityName`, `group`, `setting`, `durationText`) were verified hit-by-hit. Same-area uses are omitted. `logic/app` = non-view file in Sources/GoelApp; `test` = Tests/GoelAppTests.

Before deleting or renaming any symbol, re-check its users yourself — `grep -rnw '<Symbol>' Sources Tests` — since other areas may have changed since.

Total: 128 symbols referenced outside their owning area (MainWindow 37, Downloads 18, Detail 5, AddFlow 12, Settings 15, SFTP 8, Windows 33).

### Owner: MainWindow (37)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `A11y` | enum | AccessibilitySupport.swift | MainWindow | DiskSpaceCheck → logic/app, SpeedProfileText → logic/app, AddDownloadSheetParts → AddFlow, CommandPalette → Windows, DetailBottomPanel → Detail, DetailPanelComponents → Detail, DetailPanelView → Detail, DetailTabs → Detail, DownloadListParts → Downloads, DownloadListView → Downloads, FailureCard → Detail, FailureRecoverySheets → Detail, FileTreeView → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MenuBarView → Windows, MultiSelectionPanel → Detail, PeerRow → Detail, QueueOverviewPanel → Detail, RSSReaderView → Windows, SFTPAllTransfersView → SFTP, SFTPBrowserView → SFTP, SFTPTransferPanel → SFTP, SettingsAggregationPane → Settings, SharedViews → Downloads, SpeedGraphViews → Windows, AccessibilityLabelTests → test — A11y.sentence/bytes/speed/percent/eta |
| `DownloadKind.accessibilityName` | ext var | AccessibilitySupport.swift | MainWindow | SharedViews → Downloads |
| `DownloadTask.accessibilityKindName` | ext var | AccessibilitySupport.swift | MainWindow | DetailBottomPanel → Detail, DetailPanelView → Detail, MenuBarView → Windows, AccessibilityLabelTests → test |
| `DownloadTask.accessibilityStatusName` | ext var | AccessibilitySupport.swift | MainWindow | DetailBottomPanel → Detail, DetailPanelComponents → Detail, DetailPanelView → Detail, MenuBarView → Windows, AccessibilityLabelTests → test |
| `DownloadTask.accessibilityProgressValue` | ext var | AccessibilitySupport.swift | MainWindow | DetailBottomPanel → Detail, DetailPanelView → Detail, DetailTabs → Detail, DownloadListView → Downloads, MenuBarView → Windows, SharedViews → Downloads, AccessibilityLabelTests → test |
| `DownloadTask.accessibilityIdentityLabel` | ext var | AccessibilitySupport.swift | MainWindow | DownloadListView → Downloads, AccessibilityLabelTests → test |
| `DownloadTask.accessibilityRowLabel` | ext var | AccessibilitySupport.swift | MainWindow | AccessibilityLabelTests → test |
| `DownloadTask.accessibilityStateActionName` | ext var | AccessibilitySupport.swift | MainWindow | DownloadListView → Downloads, AccessibilityLabelTests → test |
| `A11yAnnouncer` | enum | AccessibilitySupport.swift | MainWindow | ToastQueue → logic/app, FailureRecoverySheets → Detail, SFTPBrowserView → SFTP, SettingsView → Settings |
| `SidebarFilter.accessibilityName` | ext var | AccessibilitySupport.swift | MainWindow | GoelDownloaderApp → logic/app, SidebarCatalog → logic/app, QueueOverviewPanel → Detail |
| `FileType.accessibilityName` | ext var | AccessibilitySupport.swift | MainWindow | ListPresentation → logic/app, HistoryView → Windows, FileTypeClassificationTests → test, ListGroupingTests → test |
| `SortKey.title` | ext var | AccessibilitySupport.swift | MainWindow | DownloadListView → Downloads, DisplayFormatTests → test — verified per hit |
| `SortKey.columnTitle` | ext var | AccessibilitySupport.swift | MainWindow | DownloadListView → Downloads, DisplayFormatTests → test |
| `DetailTab.title` | ext var | AccessibilitySupport.swift | MainWindow | DetailPanelView → Detail |
| `FilePriority.title` | ext var | AccessibilitySupport.swift | MainWindow | AppViewModel+Selection → logic/app, DetailBottomPanel → Detail, DetailPanelView → Detail, DetailTabs → Detail, MultiSelectionPanel → Detail — verified per hit |
| `View.a11yButton()` | ext func | AccessibilitySupport.swift | MainWindow | AddDownloadSheetParts → AddFlow, CompletedHero → Detail, DetailPanelComponents → Detail, DetailTabs → Detail, DownloadListView → Downloads, FailureCard → Detail, FileTreeView → Detail, GlobalSpeedGraphViews → Windows, MenuBarView → Windows, MultiSelectionPanel → Detail, OnboardingView → Windows, QueueOverviewPanel → Detail, RSSReaderView → Windows, SFTPBrowserView → SFTP, SFTPConnectionEditor → SFTP, SFTPTransferPanel → SFTP, SettingsPanesAutomation → Settings, SettingsView → Settings, SharedViews → Downloads |
| `View.a11yGroup()` | ext func | AccessibilitySupport.swift | MainWindow | CommandPalette → Windows, CookieSourcePicker → AddFlow, DetailBottomPanel → Detail, DetailPanelComponents → Detail, DetailPanelView → Detail, DetailTabs → Detail, DropBasketWindow → Windows, GlobalSpeedGraphViews → Windows, HistoryView → Windows, LicensePane → Settings, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MediaPresetPicker → AddFlow, MenuBarView → Windows, OnboardingView → Windows, PeerRow → Detail, SFTPBrowserView → SFTP, SFTPTransferPanel → SFTP, SettingsAggregationPane → Settings, SharedViews → Downloads, SpeedGraphViews → Windows |
| `View.a11yDecorative()` | ext func | AccessibilitySupport.swift | MainWindow | AddDownloadSheet → AddFlow, AddDownloadSheetParts → AddFlow, AutoShutdownCountdownView → Windows, BrowserCards → Settings, CommandPalette → Windows, CookieSourcePicker → AddFlow, CreateTorrentView → Windows, DetailTabs → Detail, DownloadListParts → Downloads, DownloadListView → Downloads, DropBasketWindow → Windows, FileTreeView → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, InAppPlayerView → Windows, LicensePane → Settings, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MediaPresetPicker → AddFlow, MenuBarView → Windows, MultiSelectionPanel → Detail, OnboardingView → Windows, RSSReaderView → Windows, SFTPAllTransfersView → SFTP, SFTPBrowserView → SFTP, SFTPConnectionEditor → SFTP, SFTPTransferPanel → SFTP, SFTPUploadConflictSheet → SFTP, SettingsAggregationPane → Settings, SettingsView → Settings, SharedViews → Downloads, SpeedCapPopover → Windows, SpeedGraphViews → Windows, WeeklyProfileGrid → Settings |
| `View.scaledFont()` | ext func | AccessibilitySupport.swift | MainWindow | AddDownloadSheet → AddFlow, AddDownloadSheetParts → AddFlow, AddOptionControls → AddFlow, AutoShutdownCountdownView → Windows, BrowserCards → Settings, CommandPalette → Windows, CompletedHero → Detail, CookieSourcePicker → AddFlow, CreateTorrentView → Windows, DetailBottomPanel → Detail, DetailPanelComponents → Detail, DetailPanelView → Detail, DetailTabs → Detail, DownloadListColumns → Downloads, DownloadListParts → Downloads, DownloadListView → Downloads, DropBasketWindow → Windows, ExtraTrackersSettings → Settings, FailureCard → Detail, FailureRecoverySheets → Detail, FileTreeView → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, InAppPlayerView → Windows, LicensePane → Settings, LinkGrabberSheet → AddFlow, LinkReviewView → AddFlow, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MediaPresetPicker → AddFlow, MenuBarView → Windows, MultiSelectionPanel → Detail, OnboardingPanes → Windows, OnboardingView → Windows, PeerRow → Detail, QueueOverviewPanel → Detail, RSSReaderView → Windows, RSSRuleSheet → Windows, SFTPAllTransfersView → SFTP, SFTPBrowserView → SFTP, SFTPConnectionEditor → SFTP, SFTPInfoPanel → SFTP, SFTPTransferPanel → SFTP, SFTPUploadConflictSheet → SFTP, SettingsAggregationPane → Settings, SettingsControls → Settings, SettingsPanesAutomation → Settings, SettingsPanesGrouped → Settings, SettingsRuleEditor → Settings, SettingsRulesPane → Settings, SettingsView → Settings, SharedViews → Downloads, SpeedCapPopover → Windows, SpeedGraphViews → Windows, TrackerEditing → Detail, WeeklyProfileGrid → Settings |
| `Dropdown` | struct | CustomControls.swift | MainWindow | AddDownloadSheet → AddFlow, AddOptionControls → AddFlow, LinkReviewView → AddFlow, SettingsPanesAutomation → Settings, SettingsPanesGrouped → Settings, SettingsView → Settings |
| `Dropdown.Item` | enum (nested) | CustomControls.swift | MainWindow | AddDownloadSheet → AddFlow, AddOptionControls → AddFlow, LinkReviewView → AddFlow, SettingsPanesAutomation → Settings |
| `ActionMenu` | struct | CustomControls.swift | MainWindow | DetailTabs → Detail |
| `FilePicker` | enum | PanelHelpers.swift | MainWindow | GoelDownloaderApp → logic/app, AddDownloadSheet → AddFlow, AddOptionControls → AddFlow, FailureRecoverySheets → Detail, HistoryView → Windows, MultiSelectionPanel → Detail, OnboardingView → Windows, RSSRuleSheet → Windows, SFTPBrowserView → SFTP, SettingsPanesGrouped → Settings, SettingsRuleEditor → Settings, SettingsView → Settings |
| `collectDroppedURLs()` | free func | PanelHelpers.swift | MainWindow | AddDownloadSheet → AddFlow, DropBasketWindow → Windows, SFTPBrowserView → SFTP |
| `RootView` | struct | RootView.swift | MainWindow | GoelDownloaderApp → logic/app |
| `Snail` | struct | StatusBarView.swift | MainWindow | MenuBarView → Windows |
| `Theme.TextSize` | enum (nested) | ThemeTokens.swift | MainWindow | AddDownloadSheet → AddFlow, AddDownloadSheetParts → AddFlow, AddOptionControls → AddFlow, AutoShutdownCountdownView → Windows, BrowserCards → Settings, CommandPalette → Windows, CompletedHero → Detail, CookieSourcePicker → AddFlow, CreateTorrentView → Windows, DetailBottomPanel → Detail, DetailPanelComponents → Detail, DetailPanelView → Detail, DetailTabs → Detail, DownloadListColumns → Downloads, DownloadListParts → Downloads, DownloadListView → Downloads, DropBasketWindow → Windows, ExtraTrackersSettings → Settings, FailureCard → Detail, FailureRecoverySheets → Detail, FileTreeView → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, InAppPlayerView → Windows, LicensePane → Settings, LinkGrabberSheet → AddFlow, LinkReviewView → AddFlow, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MediaPresetPicker → AddFlow, MenuBarView → Windows, MultiSelectionPanel → Detail, OnboardingPanes → Windows, OnboardingView → Windows, PeerRow → Detail, QueueOverviewPanel → Detail, RSSReaderView → Windows, RSSRuleSheet → Windows, SFTPAllTransfersView → SFTP, SFTPBrowserView → SFTP, SFTPConnectionEditor → SFTP, SFTPInfoPanel → SFTP, SFTPTransferPanel → SFTP, SFTPUploadConflictSheet → SFTP, SettingsAggregationPane → Settings, SettingsControls → Settings, SettingsPanesAutomation → Settings, SettingsPanesGrouped → Settings, SettingsRuleEditor → Settings, SettingsRulesPane → Settings, SettingsView → Settings, SharedViews → Downloads, SpeedCapPopover → Windows, SpeedGraphViews → Windows, TrackerEditing → Detail, WeeklyProfileGrid → Settings, ThemeTokenTests → test |
| `Theme.Radius` | enum (nested) | ThemeTokens.swift | MainWindow | AddDownloadSheet → AddFlow, AddDownloadSheetParts → AddFlow, AutoShutdownCountdownView → Windows, BrowserCards → Settings, CommandPalette → Windows, CompletedHero → Detail, CreateTorrentView → Windows, DropBasketWindow → Windows, FailureCard → Detail, GlobalSpeedGraphViews → Windows, LicensePane → Settings, LinkGrabberSheet → AddFlow, LinkReviewView → AddFlow, MediaFormatPicker → AddFlow, MediaJobDock → Windows, MediaPresetPicker → AddFlow, MenuBarView → Windows, OnboardingView → Windows, QRCodeView → Windows, QueueOverviewPanel → Detail, SFTPBrowserView → SFTP, SFTPConnectionEditor → SFTP, SFTPTransferPanel → SFTP, SettingsAggregationPane → Settings, SettingsControls → Settings, SettingsView → Settings, SharedViews → Downloads, SpeedGraphViews → Windows, TrackerEditing → Detail, ThemeTokenTests → test |
| `Theme.Space` | enum (nested) | ThemeTokens.swift | MainWindow | FailureRecoverySheets → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, InAppPlayerView → Windows, MultiSelectionPanel → Detail, QueueOverviewPanel → Detail, SettingsControls → Settings, SettingsPanesGrouped → Settings, SettingsView → Settings, SharedViews → Downloads |
| `Theme.fillRest` | ext static let | ThemeTokens.swift | MainWindow | CompletedHero → Detail, GlobalSpeedGraphViews → Windows, HistoryView → Windows, QueueOverviewPanel → Detail, SettingsView → Settings, SpeedGraphViews → Windows |
| `Theme.rowHover` | ext static let | ThemeTokens.swift | MainWindow | DownloadListView → Downloads |
| `Theme.fillRestAlpha()` | ext static func | ThemeTokens.swift | MainWindow | ThemeTokenTests → test |
| `Theme.fillHoverAlpha()` | ext static func | ThemeTokens.swift | MainWindow | ThemeTokenTests → test |
| `Theme.rowHoverAlpha()` | ext static func | ThemeTokens.swift | MainWindow | ThemeTokenTests → test |
| `IconButton` | struct | ThemeTokens.swift | MainWindow | CommandPalette → Windows, DetailBottomPanel → Detail, DetailTabs → Detail, HistoryView → Windows, MenuBarView → Windows, MultiSelectionPanel → Detail, SFTPAllTransfersView → SFTP, SFTPBrowserView → SFTP, SettingsRuleEditor → Settings, SettingsRulesPane → Settings, SharedViews → Downloads |
| `TintedPillButtonStyle` | struct | ThemeTokens.swift | MainWindow | CompletedHero → Detail, DetailPanelComponents → Detail, MenuBarView → Windows, MultiSelectionPanel → Detail, SharedViews → Downloads |
| `ToastOverlay` | struct | ToastOverlay.swift | MainWindow | SettingsView → Settings |

### Owner: Downloads (18)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `ExtraColumnText` | enum | DownloadListColumns.swift | Downloads | Wave3MacBTests → test |
| `DownloadListView` | struct | DownloadListView.swift | Downloads | RootView → MainWindow |
| `DownloadColumns` | struct | DownloadListView.swift | Downloads | ListColumnsTests → test, QueueCellFormatTests → test, WindowLayoutTests → test |
| `DownloadColumns.Layout` | enum (nested) | DownloadListView.swift | Downloads | WindowLayoutTests → test |
| `CompletedHeroMoreMenu` | struct | FileActionMenus.swift | Downloads | CompletedHero → Detail |
| `SheetHeader` | struct | SharedViews.swift | Downloads | AddDownloadSheet → AddFlow, FailureRecoverySheets → Detail, LinkGrabberSheet → AddFlow, OnboardingView → Windows, SFTPConnectionEditor → SFTP, SettingsRuleEditor → Settings, SpeedGraphViews → Windows |
| `SheetFooter` | struct | SharedViews.swift | Downloads | FailureRecoverySheets → Detail, OnboardingView → Windows, SFTPUploadConflictSheet → SFTP, SpeedGraphViews → Windows |
| `SheetFooter.init(cancelTitle:)` | ext init | SharedViews.swift | Downloads | OnboardingView → Windows |
| `EmptyStateView` | struct | SharedViews.swift | Downloads | CommandPalette → Windows, HistoryView → Windows, InAppPlayerView → Windows, MenuBarView → Windows, SFTPBrowserView → SFTP, SFTPTransferPanel → SFTP |
| `SpeedStat` | struct | SharedViews.swift | Downloads | DetailPanelComponents → Detail, MenuBarView → Windows, SFTPTransferPanel → SFTP |
| `SFTPTransferRow` | struct | SharedViews.swift | Downloads | MenuBarView → Windows, StatusBarView → MainWindow |
| `FileTypeIcon` | struct | SharedViews.swift | Downloads | CompletedHero → Detail, DetailBottomPanel → Detail, DetailPanelView → Detail, HistoryView → Windows, MenuBarView → Windows, MultiSelectionPanel → Detail |
| `KindBadge` | struct | SharedViews.swift | Downloads | AddDownloadSheetParts → AddFlow, DetailBottomPanel → Detail, DetailPanelView → Detail, MenuBarView → Windows |
| `MiniProgressBar` | struct | SharedViews.swift | Downloads | DetailBottomPanel → Detail, MenuBarView → Windows |
| `IndeterminateBar` | struct | SharedViews.swift | Downloads | IndeterminateBarTests → test |
| `RowStateAction` | enum | SharedViews.swift | Downloads | RowStateActionTests → test |
| `StateButton` | struct | SharedViews.swift | Downloads | MenuBarView → Windows |
| `PastedFromClipboardNote` | struct | SharedViews.swift | Downloads | AddDownloadSheet → AddFlow, LinkGrabberSheet → AddFlow |

### Owner: Detail (5)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `DetailBottomPanel` | struct | DetailBottomPanel.swift | Detail | RootView → MainWindow |
| `DetailPanelHeight` | enum | DetailPanelResizeHandle.swift | Detail | RootView → MainWindow, QueueCellFormatTests → test |
| `DetailPanelResizeHandle` | struct | DetailPanelResizeHandle.swift | Detail | RootView → MainWindow |
| `DetailPanelView` | struct | DetailPanelView.swift | Detail | RootView → MainWindow |
| `SectionLabel` | struct | DetailTabs.swift | Detail | SpeedGraphViews → Windows |

### Owner: AddFlow (12)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `AddDownloadSheet` | struct | AddDownloadSheet.swift | AddFlow | RootView → MainWindow |
| `SaveFolderPicker` | struct | AddOptionControls.swift | AddFlow | AddReviewAndOutcomeTests → test |
| `WhenDonePicker` | struct | AddOptionControls.swift | AddFlow | FileActionMenus → Downloads, SettingsRuleEditor → Settings, SettingsRulesPane → Settings |
| `CookieSourcePicker` | struct | CookieSourcePicker.swift | AddFlow | FailureRecoverySheets → Detail |
| `LinkGrabberSheet` | struct | LinkGrabberSheet.swift | AddFlow | RootView → MainWindow |
| `GrabbedLink` | struct | LinkGrabberSheet.swift | AddFlow | LinkReview → logic/app |
| `GrabbedLink.Category` | enum (nested) | LinkGrabberSheet.swift | AddFlow | LinkReview → logic/app |
| `LinkExtractor` | enum | LinkGrabberSheet.swift | AddFlow | LinkReview → logic/app, AddReviewAndOutcomeTests → test |
| `LinkGrabberPrefill` | enum | LinkGrabberSheet.swift | AddFlow | QueueCellFormatTests → test |
| `AddSheetInput` | enum | SheetFormHelpers.swift | AddFlow | SheetFormHelpersTests → test |
| `RemoteNameInput` | enum | SheetFormHelpers.swift | AddFlow | SFTPBrowserView → SFTP, SheetFormHelpersTests → test |
| `SFTPConnectionForm` | enum | SheetFormHelpers.swift | AddFlow | SFTPConnectionEditor → SFTP, SheetFormHelpersTests → test |

### Owner: Settings (15)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `BrowserStatusCards` | struct | BrowserCards.swift | Settings | OnboardingPanes → Windows |
| `BrowserCard` | struct | BrowserCards.swift | Settings | Wave3MacBTests → test |
| `EnvironmentValues.settingRowName` | ext var | SettingsControls.swift | Settings | CustomControls → MainWindow |
| `SettingSwitch` | struct | SettingsControls.swift | Settings | OnboardingPanes → Windows, OnboardingView → Windows |
| `setting()` | free func | SettingsPanesAutomation.swift | Settings | OnboardingPanes → Windows, OnboardingView → Windows — free func `setting(vm, \.keyPath)` Binding helper |
| `RulesPreview` | enum | SettingsRulesPane.swift | Settings | AddReviewAndOutcomeTests → test |
| `SettingsView.Pane.Group` | enum (nested) | SettingsSearch.swift | Settings | SheetFormHelpersTests → test |
| `SettingsView.Pane.group` | ext var | SettingsSearch.swift | Settings | CommandPalette → Windows — verified: CommandPalette L288 only |
| `SettingsView.Pane.searchKeywords` | ext var | SettingsSearch.swift | Settings | SheetFormHelpersTests → test |
| `SettingsSearch` | enum | SettingsSearch.swift | Settings | CommandPalette → Windows, SettingsRowSearchTests → test, SheetFormHelpersTests → test |
| `SettingsSearch.Index` | struct (nested) | SettingsSearch.swift | Settings | SheetFormHelpersTests → test |
| `SettingsView` | struct | SettingsView.swift | Settings | GoelDownloaderApp → logic/app, CommandPalette → Windows, EmptyStateView → MainWindow, SheetFormHelpersTests → test |
| `SettingsView.Pane` | enum (nested) | SettingsView.swift | Settings | CommandPalette → Windows, EmptyStateView → MainWindow, SheetFormHelpersTests → test — SettingsView.Pane |
| `ProfileScheduleSummary` | enum | WeeklyProfileGrid.swift | Settings | Wave3MacBTests → test |
| `WeeklyProfileGrid` | struct | WeeklyProfileGrid.swift | Settings | Wave3MacBTests → test |

### Owner: SFTP (8)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `SFTPTransferSummary` | struct | SFTPAllTransfersView.swift | SFTP | SidebarView → MainWindow, Wave3MacBTests → test |
| `SFTPTransfersSidebarRow` | struct | SFTPAllTransfersView.swift | SFTP | SidebarView → MainWindow |
| `SFTPAllTransfersView` | struct | SFTPAllTransfersView.swift | SFTP | SidebarView → MainWindow |
| `QuickLookPresenter` | class | SFTPBrowserSupport.swift | SFTP | MenuBarView → Windows, RootView → MainWindow |
| `SFTPBrowserView` | struct | SFTPBrowserView.swift | SFTP | RootView → MainWindow |
| `SFTPConnectionEditor` | struct | SFTPConnectionEditor.swift | SFTP | RootView → MainWindow |
| `SFTPEntryInfo` | struct | SFTPInfoPanel.swift | SFTP | SFTPBrowserModel → logic/app |
| `SFTPUploadConflictSheet` | struct | SFTPUploadConflictSheet.swift | SFTP | RootView → MainWindow |

### Owner: Windows (33)

| Symbol | Kind | Defined in | Owner area | Used by (file → area) |
|---|---|---|---|---|
| `MarkdownText` | enum | MarkdownText.swift | Windows | AddDownloadSheet → AddFlow — `MarkdownText.attributed(_:)` |
| `QRCodeView` | struct | QRCodeView.swift | Windows | SettingsPanesAutomation → Settings — `QRCodeView(text:)` |
| `LANAddress` | enum | QRCodeView.swift | Windows | SettingsPanesAutomation → Settings — `LANAddress.primaryIPv4()` |
| `AutoShutdownCountdownView` | struct | AutoShutdownCountdownView.swift | Windows | RootView → MainWindow |
| `CommandPaletteBus` | enum | CommandPalette.swift | Windows | GoelDownloaderApp → logic/app, AppToolbar → MainWindow, EmptyStateView → MainWindow, RootView → MainWindow |
| `SettingsRoute` | class | CommandPalette.swift | Windows | EmptyStateView → MainWindow, FailureCard → Detail, SettingsView → Settings, StatusBarView → MainWindow — settings deep-link singleton |
| `CommandPalette` | struct | CommandPalette.swift | Windows | RootView → MainWindow |
| `CreateTorrentWindow` | class | CreateTorrentView.swift | Windows | GoelDownloaderApp → logic/app |
| `DropBasketController` | class | DropBasketWindow.swift | Windows | GoelDownloaderApp → logic/app, EmptyStateView → MainWindow, SettingsPanesAutomation → Settings, ToolbarExtras → MainWindow |
| `SpeedDirection` | enum | GlobalSpeedGraphViews.swift | Windows | QueueOverviewPanel → Detail, StatusBarView → MainWindow |
| `GlobalSpeedSparkline` | struct | GlobalSpeedGraphViews.swift | Windows | StatusBarView → MainWindow |
| `GlobalSpeedHistoryPopover` | struct | GlobalSpeedGraphViews.swift | Windows | TelemetryAndTransferStoreTests → test |
| `HistoryView` | struct | HistoryView.swift | Windows | GoelDownloaderApp → logic/app |
| `ScheduledStartOption` | struct | HistoryView.swift | Windows | AddDownloadSheet → AddFlow, DownloadListView → Downloads, LinkReviewView → AddFlow |
| `PlayerWindow` | struct | InAppPlayerView.swift | Windows | GoelDownloaderApp → logic/app |
| `MediaJobDock` | struct | MediaJobDock.swift | Windows | RootView → MainWindow |
| `MediaJobCenter.Job.durationText()` | ext static func | MediaJobDock.swift | Windows | MediaJobCenterTests → test |
| `MainWindowID` | enum | MenuBarView.swift | Windows | GoelDownloaderApp → logic/app, MainWindowPresenter → logic/app, RootView → MainWindow — window id used by scenes |
| `MenuBarView` | struct | MenuBarView.swift | Windows | GoelDownloaderApp → logic/app |
| `MenuBarQueue` | struct | MenuBarView.swift | Windows | MenuBarQueueTests → test |
| `MenuBarJustFinished` | struct | MenuBarView.swift | Windows | MenuBarJustFinishedTests → test |
| `MenuBarAttention` | struct | MenuBarView.swift | Windows | QueueCellFormatTests → test |
| `MenuBarSpeedLabel` | struct | MenuBarView.swift | Windows | GoelDownloaderApp → logic/app |
| `OnboardingBrowserChoice` | enum | OnboardingPanes.swift | Windows | Wave3MacBTests → test |
| `OnboardingState` | enum | OnboardingView.swift | Windows | LicensePane → Settings, RootView → MainWindow |
| `OnboardingView` | struct | OnboardingView.swift | Windows | RootView → MainWindow |
| `RSSReaderView` | struct | RSSReaderView.swift | Windows | RootView → MainWindow |
| `SpeedCapPopover` | struct | SpeedCapPopover.swift | Windows | StatusBarView → MainWindow |
| `AppViewModel.applyCustomSpeedCap()` | ext func | SpeedCapPopover.swift | Windows | StatusBarView → MainWindow |
| `SparklineView` | struct | SpeedGraphViews.swift | Windows | QueueOverviewPanel → Detail, SFTPTransferPanel → SFTP |
| `TaskSpeedGraph` | struct | SpeedGraphViews.swift | Windows | DetailBottomPanel → Detail, DetailPanelView → Detail |
| `SpeedHistoryWindow` | enum | SpeedGraphViews.swift | Windows | TelemetryAndTransferStoreTests → test |
| `StatsView` | struct | SpeedGraphViews.swift | Windows | RootView → MainWindow |

### Views symbols used by app entry points (scenes, commands, presenters)

| App file | Views symbols (owner area) |
|---|---|
| GoelDownloaderApp.swift | CommandPaletteBus (Windows), CreateTorrentWindow (Windows), DropBasketController (Windows), FilePicker (MainWindow), HistoryView (Windows), MainWindowID (Windows), MenuBarSpeedLabel (Windows), MenuBarView (Windows), PlayerWindow (Windows), RootView (MainWindow), SettingsView (Settings), SidebarFilter.accessibilityName (MainWindow) |
| MainWindowPresenter.swift | MainWindowID (Windows) |
| AppIntents.swift | none |
| ScriptingSupport.swift | none |
| DockMenu.swift | none |
| NotificationService.swift | none |
| LiveSystemActions.swift | none |
| ExternalAddRouter.swift | none |
| HostKeyApprovalPresenter.swift | none |
| main.swift | none |

## 6. Tests

`Tests/GoelAppTests/StudioDesignSystemTests.swift` covers the foundation (appearance migration,
token contrast, OKLCH, font registration, snapshot names, the sample model) — keep it green.
The tests below reference view-layer symbols; the owning area keeps them compiling and passing
(update the test only when the behaviour it pins genuinely moved, never to make it pass).

### Tests touching view-layer symbols

| Test file | Views symbols referenced (owner area) | Owning area |
|---|---|---|
| AccessibilityLabelTests.swift | `A11y` (MainWindow), `DownloadTask.accessibilityKindName` (MainWindow), `DownloadTask.accessibilityStatusName` (MainWindow), `DownloadTask.accessibilityProgressValue` (MainWindow), `DownloadTask.accessibilityIdentityLabel` (MainWindow), `DownloadTask.accessibilityRowLabel` (MainWindow), `DownloadTask.accessibilityStateActionName` (MainWindow) | MainWindow |
| AddInputParsingTests.swift | — | logic only, no area |
| AddReviewAndOutcomeTests.swift | `SaveFolderPicker` (AddFlow), `LinkExtractor` (AddFlow), `RulesPreview` (Settings) | AddFlow + Settings |
| AutoShutdownCountdownTests.swift | — | logic only, no area |
| BrowserSpoolTests.swift | — | logic only, no area |
| CommandStateTests.swift | — | logic only, no area |
| CompletionSummaryTests.swift | — | logic only, no area |
| DiskSpaceCheckTests.swift | — | logic only, no area |
| DisplayFormatTests.swift | `SortKey.title` (MainWindow), `SortKey.columnTitle` (MainWindow) | MainWindow |
| ExternalAddRoutingTests.swift | — | logic only, no area |
| FFmpegOutputNamingTests.swift | — | logic only, no area |
| FFmpegOverrideTests.swift | — | logic only, no area |
| FailureAdviceTests.swift | — | logic only, no area |
| FileProgressPublisherTests.swift | — | logic only, no area |
| FileTreeTests.swift | — | logic only, no area |
| FileTypeClassificationTests.swift | `FileType.accessibilityName` (MainWindow) | MainWindow |
| FontScalingDriftTests.swift | — | logic only, no area |
| InAppPlaybackTests.swift | — | logic only, no area |
| InboundDropTests.swift | — | logic only, no area |
| IndeterminateBarTests.swift | `IndeterminateBar` (Downloads) | Downloads |
| InlineCredentialsTests.swift | — | logic only, no area |
| KnownHostsCheckTests.swift | — | logic only, no area |
| ListColumnsTests.swift | `DownloadColumns` (Downloads) | Downloads |
| ListGroupingTests.swift | `FileType.accessibilityName` (MainWindow) | MainWindow |
| ListPresentationTests.swift | — | logic only, no area |
| MediaJobCenterTests.swift | `MediaJobCenter.Job.durationText()` (Windows) | Windows |
| MediaPageLinkTests.swift | — | logic only, no area |
| MenuBarJustFinishedTests.swift | `MenuBarJustFinished` (Windows) | Windows |
| MenuBarQueueTests.swift | `MenuBarQueue` (Windows) | Windows |
| PendingMagnetTitleTests.swift | — | logic only, no area |
| QueueCellFormatTests.swift | `DetailPanelHeight` (Detail), `DownloadColumns` (Downloads), `LinkGrabberPrefill` (AddFlow), `MenuBarAttention` (Windows) | Downloads + Detail + AddFlow + Windows |
| RemovalReportTests.swift | — | logic only, no area |
| RowStateActionTests.swift | `RowStateAction` (Downloads) | Downloads |
| SFTPAddressImportTests.swift | — | logic only, no area |
| SFTPBrowserLocationStoreTests.swift | — | logic only, no area |
| SFTPBrowserNavigationTests.swift | — | logic only, no area |
| SFTPClipboardTests.swift | — | logic only, no area |
| SFTPServerActionTests.swift | — | logic only, no area |
| SFTPTransferStateTests.swift | — | logic only, no area |
| SelectionAggregateTests.swift | — | logic only, no area |
| SelectionRangeTests.swift | — | logic only, no area |
| ServerOSParsingTests.swift | — | logic only, no area |
| SettingsRowSearchTests.swift | `SettingsSearch` (Settings) | Settings |
| SheetFormHelpersTests.swift | `SettingsView.Pane.Group` (Settings), `SettingsView.Pane.searchKeywords` (Settings), `SettingsSearch` (Settings), `SettingsSearch.Index` (Settings), `SettingsView` (Settings), `SettingsView.Pane` (Settings), `AddSheetInput` (AddFlow), `RemoteNameInput` (AddFlow), `SFTPConnectionForm` (AddFlow) | Settings + AddFlow |
| SpeedProfileTextTests.swift | — | logic only, no area |
| TaskDisplayTests.swift | — | logic only, no area |
| TelemetryAndTransferStoreTests.swift | `GlobalSpeedHistoryPopover` (Windows), `SpeedHistoryWindow` (Windows) | Windows |
| ThemeTokenTests.swift | `Theme.TextSize` (MainWindow), `Theme.Radius` (MainWindow), `Theme.fillRestAlpha()` (MainWindow), `Theme.fillHoverAlpha()` (MainWindow), `Theme.rowHoverAlpha()` (MainWindow) | MainWindow |
| ToastQueueTests.swift | — | logic only, no area |
| UpdateCheckerTests.swift | — | logic only, no area |
| Wave3MacBTests.swift | `BrowserCard` (Settings), `ExtraColumnText` (Downloads), `OnboardingBrowserChoice` (Windows), `SFTPTransferSummary` (SFTP), `ProfileScheduleSummary` (Settings), `WeeklyProfileGrid` (Settings) | Settings + Downloads + SFTP + Windows |
| WindowLayoutTests.swift | `DownloadColumns` (Downloads), `DownloadColumns.Layout` (Downloads) | Downloads |
| YtDlpPreviewTests.swift | — | logic only, no area |

### Source-scanning tests (path/text coupling, not symbol coupling)

- `SheetFormHelpersTests.testEverySetRowTitleIsInTheSearchIndex` (Settings): reads every `*.swift` directly in `Sources/GoelApp/Views` (non-recursive) and regex-scrapes `SetRow(name: L10n.t("…"))`; needs > 50 matches and every title in `SettingsView.Pane.searchKeywords`. Moving settings panes into a subfolder, renaming `SetRow`, or changing the `name:` label breaks it.
- `FontScalingDriftTests` (all areas): walks all of `Sources/GoelApp` recursively and fails on any `.font(.system(size:` without a `// fixed-size:` comment on that or the previous line. New UI uses `.studioFont(_:)` (or `.scaledFont(size:)`).
