#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT="$PROJECT_DIR/Sift.xcodeproj"
SCHEME="Sift"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/SiftDevDerivedData}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="Sift.app"
APP_EXECUTABLE="Sift"
POLL_INTERVAL="${POLL_INTERVAL:-0.5}"
DEBOUNCE_INTERVAL="${DEBOUNCE_INTERVAL:-0.25}"
LAUNCH="${LAUNCH:-1}"
QUIET="${QUIET:-1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--once]

Watches Sift source files, then rebuilds, reinstalls, and relaunches
$INSTALL_DIR/$APP_NAME whenever they change.

Environment:
  CONFIGURATION      Xcode configuration to build. Default: Debug
  DERIVED_DATA       DerivedData path. Default: /tmp/SiftDevDerivedData
  INSTALL_DIR        App install directory. Default: \$HOME/Applications
  POLL_INTERVAL      File-change polling interval in seconds. Default: 0.5
  DEBOUNCE_INTERVAL  Delay after detecting a change before rebuilding. Default: 0.25
  LAUNCH             Set to 0 to install without launching. Default: 1
  QUIET              Set to 0 to show full xcodebuild output. Default: 1
EOF
}

ONCE=0
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ "${1:-}" == "--once" ]]; then
  ONCE=1
elif [[ $# -gt 0 ]]; then
  usage >&2
  exit 2
fi

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
DEST_APP="$INSTALL_DIR/$APP_NAME"

snapshot() {
  /usr/bin/find \
    "$PROJECT_DIR/Sift" \
    "$PROJECT_DIR/Sift.xcodeproj/project.pbxproj" \
    "$PROJECT_DIR/Sift.xcodeproj/project.xcworkspace/contents.xcworkspacedata" \
    -type f \
    ! -path "*/xcuserdata/*" \
    -print0 \
    | /usr/bin/xargs -0 /usr/bin/stat -f "%m %z %N" \
    | /usr/bin/shasum \
    | /usr/bin/awk '{print $1}'
}

stop_running_app() {
  if ! /usr/bin/pgrep -x "$APP_EXECUTABLE" >/dev/null; then
    return 0
  fi

  echo "Stopping $APP_EXECUTABLE..."
  /usr/bin/pkill -x "$APP_EXECUTABLE" || true

  for _ in {1..30}; do
    if ! /usr/bin/pgrep -x "$APP_EXECUTABLE" >/dev/null; then
      return 0
    fi

    sleep 0.1
  done

  echo "Force stopping $APP_EXECUTABLE..."
  /usr/bin/pkill -9 -x "$APP_EXECUTABLE" || true
}

build_install_launch() {
  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild_args=(
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build
  )

  if [[ "$QUIET" != "0" ]]; then
    xcodebuild_args=(-quiet "${xcodebuild_args[@]}")
  fi

  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "${xcodebuild_args[@]}"

  if [[ ! -d "$BUILT_APP" ]]; then
    echo "Built app not found at: $BUILT_APP" >&2
    return 1
  fi

  stop_running_app
  mkdir -p "$INSTALL_DIR"

  if [[ -d "$DEST_APP" ]]; then
    rm -rf "$DEST_APP"
  fi

  echo "Installing to $DEST_APP..."
  /usr/bin/ditto "$BUILT_APP" "$DEST_APP"

  if [[ "$LAUNCH" != "0" ]]; then
    echo "Launching $DEST_APP..."
    /usr/bin/open "$DEST_APP"
  fi

  echo "Ready."
}

if [[ "$ONCE" == "1" ]]; then
  build_install_launch
  exit $?
fi

build_install_launch || true
last_snapshot="$(snapshot)"

echo "Watching for changes. Press Ctrl-C to stop."
while true; do
  sleep "$POLL_INTERVAL"
  current_snapshot="$(snapshot)"

  if [[ "$current_snapshot" != "$last_snapshot" ]]; then
    echo "Change detected."
    sleep "$DEBOUNCE_INTERVAL"

    if build_install_launch; then
      last_snapshot="$(snapshot)"
    else
      echo "Build failed. Waiting for the next change."
      last_snapshot="$current_snapshot"
    fi
  fi
done
