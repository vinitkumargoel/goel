# T11 — Library + Files integration

**Goal:** frame 8 of `visual.html` (shown in light mode) plus PRD §4.2 — *"there is no
filesystem, so make Files the feature."*

## Build

**`Features/Library/LibraryView.swift`**
- Large title `Library`, trailing `Select`.
- Segmented: Recent / Folders / Media.
- Rows reuse the T07 row anatomy but show `412.3 MB · Verified · Today` instead of live
  progress, with a share/export trailing button.
- Media tab: a grid of thumbnails for video/image files, generated with
  `AVAssetImageGenerator` / `QuickLookThumbnailing`, **cached to disk** — regenerating on
  every scroll will make it crawl.
- The informational card from the mockup, verbatim in spirit: *"Everything here also
  appears in the **Files** app under Goel° — nothing is trapped inside this app."*

**Files integration** — this is the substance of the task:
- `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (already set in T01) make
  the app's `Documents/` visible in Files under "On My iPhone → Goel°". Downloads must land
  in `Documents/`, **not** in `Application Support` or `tmp`, or none of this works.
- Share out: `ShareLink` / `UIActivityViewController` on every completed file.
- "Save to…" via `.fileExporter` or `UIDocumentPickerViewController` so a user can move a
  file to iCloud Drive.
- Folder organization inside the container, with create / rename / delete.

**Path safety:** all file operations go through one helper that verifies the target is
inside the container. Mirror the desktop's `PathSafety.isContained` choke point. Reject
`..` traversal in any user-supplied folder name. There is exactly one place in the app that
resolves a save path — do not scatter this.

**A File Provider extension is NOT tonight's work.** The PRD lists it as the full solution;
`UIFileSharingEnabled` gets most of the value for a fraction of the cost. Note the gap in
`REPORT.md`.

## Exit criteria

- Complete a download, then open the **Files** app on the simulator and confirm the file
  appears under On My iPhone → Goel°. Screenshot that: `T11-files-app.png`. This is the
  proof, and it is worth taking.
- `Scripts/ios/sim.sh shot T11-library-light` (appearance light — the mockup shows this
  screen light). **Read it**, compare to frame 8. Confirm ember has shifted to `#E85D18`
  and the screen looks deliberately designed rather than inverted.
- Share sheet opens and lists real destinations.
- `git commit -m "ios(T11): library and Files app integration"`

## Notes

- If the app does not appear in Files, the usual causes are: the plist keys missing from
  the **app** target (not the widget), files written outside `Documents/`, or the app never
  having written anything at all — Files hides empty providers.
