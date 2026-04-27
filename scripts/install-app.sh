#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT="$PROJECT_DIR/Sift.xcodeproj"
SCHEME="Sift"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/SiftDerivedData}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="Sift.app"

echo "Building $SCHEME ($CONFIGURATION)..."
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
DEST_APP="$INSTALL_DIR/$APP_NAME"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found at: $BUILT_APP" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

if [[ -d "$DEST_APP" ]]; then
  echo "Replacing $DEST_APP..."
  rm -rf "$DEST_APP"
fi

echo "Installing to $DEST_APP..."
/usr/bin/ditto "$BUILT_APP" "$DEST_APP"

echo "Done."
echo "$DEST_APP"
