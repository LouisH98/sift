#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT="$PROJECT_DIR/Sift.xcodeproj"
SCHEME="${SCHEME:-SiftTests}"
ARCH="${ARCH:-$(uname -m)}"
DESTINATION="${DESTINATION:-platform=macOS,arch=$ARCH}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/DerivedData}"

echo "Running $SCHEME tests..."
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA"
