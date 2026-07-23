# T01 — Xcode project scaffold

**Goal:** an app + widget-extension project that builds and launches on the booted simulator.
Nothing else. Get the loop working before you write any product code.

## Build

1. `git checkout -b ios-app-impl`

2. `apps/ios/project.yml` for xcodegen. Two targets:

   - **`Goel`** — `application`, bundle ID `dev.goel.ios`, deployment target iOS 18.0,
     Swift 6 language mode, sources `Goel/` + `Shared/`.
   - **`GoelWidgets`** — `app-extension`, bundle ID `dev.goel.ios.widgets`, sources
     `GoelWidgets/` + `Shared/`. **`Shared/` is a member of both targets** — that is how
     the widget sees the activity attributes and theme.

   `Goel` depends on `GoelWidgets` with `embed: true`.
   Add a `GoelTests` unit-test target (`bundle.unit-test`) hosted by `Goel`.

3. **Info.plist keys that matter:**
   - App: `NSSupportsLiveActivities = true` (T13 fails silently without it),
     `UIBackgroundModes = [fetch, processing]`, `UIFileSharingEnabled = true`,
     `LSSupportsOpeningDocumentsInPlace = true` (T11 needs both).
   - Widget: `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.

4. **Entitlements** — both targets get `com.apple.security.application-groups = [group.dev.goel.ios]`.

5. `GoelApp.swift` — `@main`, a single view reading `Goel°` centered on black. That is all.

6. `GoelWidgetsBundle.swift` — `@main struct GoelWidgetsBundle: WidgetBundle` with an
   empty-but-valid placeholder `StaticConfiguration` widget so the extension compiles.

7. `Scripts/ios/sim.sh` — the loop from `CONVENTIONS.md`, parameterized:
   `./Scripts/ios/sim.sh build | run | shot <name> | test`.
   Make it executable. You will run it dozens of times tonight.

## Exit criteria

- `xcodebuild ... build` succeeds with zero errors.
- `xcrun simctl install` + `launch` puts the app on screen.
- `Scripts/ios/sim.sh shot T01-hello` produces `tasks/ios-app/shots/T01-hello.png`, and
  **you have Read it** and confirmed it shows the app, not a crash or a black frame.
- `git commit -m "ios(T01): xcode project scaffold with widget extension"`

## Notes

- If the widget extension fails to embed, check that `GoelWidgets` is listed under the
  app's `dependencies:` with `embed: true` **and** `codeSign: false`.
- Do not add SPM dependencies. Do not reference the root `Package.swift`.
- `xcodegen generate` must be re-run after every `project.yml` edit and after adding any
  new *directory* of sources. Adding a file to an existing directory does not need it,
  because `project.yml` globs by folder.
