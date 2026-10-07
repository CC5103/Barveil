#!/bin/zsh
# Free direct-distribution packaging: builds a Release (ad-hoc signed unless
# BARVEIL_CODESIGN_IDENTITY / BARVEIL_DEVELOPMENT_TEAM are set), then writes
# dist/Barveil-<version>.zip, dist/Barveil-<version>.dmg and
# dist/SHA256SUMS.txt. No Apple developer account required.
#
#   scripts/package.sh                    # ad-hoc, users open it once via
#                                         # right-click → Open
#   BARVEIL_CODESIGN_IDENTITY="Developer ID Application: Name (TEAM)" \
#     BARVEIL_DEVELOPMENT_TEAM=TEAM scripts/package.sh
#
# For Developer ID + notarization (no Gatekeeper prompt for users) use
# scripts/notarize.sh instead; see the script header for notarization details.

set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="${BARVEIL_DERIVED_DATA:-${TMPDIR:-/tmp}/barveil-derived-data}"
APP="$DERIVED_DATA/Build/Products/Release/Barveil.app"

echo "==> Building Release"
scripts/build.sh Release

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || VERSION="1.0.0"

mkdir -p dist
STAGE="$DERIVED_DATA/package-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Barveil-$VERSION" "$STAGE/dmg"

# --- zip: app + license files side by side --------------------------------
ditto "$APP" "$STAGE/Barveil-$VERSION/Barveil.app"
ditto LICENSE "$STAGE/Barveil-$VERSION/LICENSE"
rm -f "dist/Barveil-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$STAGE/Barveil-$VERSION" "dist/Barveil-$VERSION.zip"

# --- dmg: drag-to-Applications layout -------------------------------------
ditto "$APP" "$STAGE/dmg/Barveil.app"
ditto LICENSE "$STAGE/dmg/LICENSE"
ln -sfn /Applications "$STAGE/dmg/Applications"
rm -f "dist/Barveil-$VERSION.dmg"
hdiutil create -quiet -volname "Barveil $VERSION" -srcfolder "$STAGE/dmg" -ov -format UDZO "dist/Barveil-$VERSION.dmg"

# --- checksums -------------------------------------------------------------
(cd dist && shasum -a 256 "Barveil-$VERSION.zip" "Barveil-$VERSION.dmg" > SHA256SUMS.txt)

echo
echo "packaged:"
(cd dist && ls -lh "Barveil-$VERSION.zip" "Barveil-$VERSION.dmg" SHA256SUMS.txt)
echo
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -1
echo
cat dist/SHA256SUMS.txt
