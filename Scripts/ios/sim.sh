#!/usr/bin/env bash
# Goel° iOS — the build → install → launch → screenshot loop.
#
#   ./Scripts/ios/sim.sh gen            regenerate the Xcode project from project.yml
#   ./Scripts/ios/sim.sh build          build for the booted simulator
#   ./Scripts/ios/sim.sh run [args...]  install + launch (args are passed to the app)
#   ./Scripts/ios/sim.sh preview        install + launch with -uiTestingPreviewEngine
#   ./Scripts/ios/sim.sh shot <name>    screenshot into tasks/ios-app/shots/<name>.png
#   ./Scripts/ios/sim.sh test           run the unit tests
#   ./Scripts/ios/sim.sh appearance dark|light
#   ./Scripts/ios/sim.sh statusbar      pin the status bar to 9:41 for comparable shots
#   ./Scripts/ios/sim.sh home           background the app (SpringBoard) for Island shots
#   ./Scripts/ios/sim.sh clean          uninstall the app and wipe DerivedData
#   ./Scripts/ios/sim.sh log            stream the app's os_log output
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SIM="${SIM:-BC332A27-A788-413C-910B-7686447B73F1}"
APP_ID="dev.goel.ios"
IOS_DIR="apps/ios"
PROJ="$IOS_DIR/Goel.xcodeproj"
DD="${DD:-$IOS_DIR/.build}"
SHOTS="tasks/ios-app/shots"
APP_PATH="$DD/Build/Products/Debug-iphonesimulator/Goel.app"

cmd="${1:-build}"; shift || true

gen() {
  ( cd "$IOS_DIR" && xcodegen generate --quiet )
}

build() {
  gen
  set +e
  xcodebuild -project "$PROJ" -scheme Goel \
    -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath "$DD" \
    build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* " | sort -u | head -60
  rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

case "$cmd" in
  gen)   gen ;;
  build) build ;;

  run|preview)
    build
    xcrun simctl install "$SIM" "$APP_PATH"
    xcrun simctl terminate "$SIM" "$APP_ID" >/dev/null 2>&1 || true
    if [ "$cmd" = "preview" ]; then
      xcrun simctl launch "$SIM" "$APP_ID" -uiTestingPreviewEngine "$@"
    else
      xcrun simctl launch "$SIM" "$APP_ID" "$@"
    fi
    ;;

  install)
    xcrun simctl install "$SIM" "$APP_PATH"
    ;;

  launch)
    xcrun simctl terminate "$SIM" "$APP_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIM" "$APP_ID" "$@"
    ;;

  shot)
    name="${1:?usage: sim.sh shot <name>}"
    mkdir -p "$SHOTS/$(dirname "$name")"
    xcrun simctl io "$SIM" screenshot "$SHOTS/$name.png" >/dev/null 2>&1
    echo "$SHOTS/$name.png"
    ;;

  test)
    gen
    set +e
    xcodebuild -project "$PROJ" -scheme Goel \
      -destination "platform=iOS Simulator,id=$SIM" \
      -derivedDataPath "$DD" \
      test 2>&1 | grep -E "error:|Test Case.*(passed|failed)|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|✘|◇|✔|\*\* " | tail -60
    rc=${PIPESTATUS[0]}
    set -e
    return $rc 2>/dev/null || exit $rc
    ;;

  appearance)
    xcrun simctl ui "$SIM" appearance "${1:-dark}"
    ;;

  statusbar)
    xcrun simctl status_bar "$SIM" override --time "9:41" \
      --batteryState charged --batteryLevel 100 --cellularBars 4 --dataNetwork wifi
    ;;

  home)
    xcrun simctl launch "$SIM" com.apple.springboard >/dev/null
    ;;

  clean)
    xcrun simctl uninstall "$SIM" "$APP_ID" >/dev/null 2>&1 || true
    rm -rf "$DD"
    ;;

  log)
    xcrun simctl spawn "$SIM" log stream --predicate 'subsystem == "dev.goel.ios"' --style compact
    ;;

  container)
    xcrun simctl get_app_container "$SIM" "$APP_ID" "${1:-data}"
    ;;

  *)
    echo "unknown command: $cmd" >&2
    sed -n '2,15p' "$0" >&2
    exit 2
    ;;
esac
