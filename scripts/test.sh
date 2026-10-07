#!/bin/zsh
# Logic tests for the decision table.

set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="${BARVEIL_DERIVED_DATA:-${TMPDIR:-/tmp}/barveil-derived-data}"

xcodebuild \
  -project Barveil.xcodeproj \
  -scheme Barveil \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  test
