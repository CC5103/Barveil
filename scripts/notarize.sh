#!/bin/zsh
# Developer ID + notarization pipeline for Barveil.
#
# Builds an unsigned Release, signs it with your Developer ID Application
# identity + Config/Barveil.entitlements + hardened runtime, notarizes and
# staples the .app, then packages and notarizes a DMG.
#
# Prerequisites:
#   1. Apple Developer Program + a valid "Developer ID Application" cert in
#      the login keychain (Xcode can auto-create it under
#      Settings > Accounts > Manage Certificates).
#   2. Notary credentials stored once:
#        xcrun notarytool store-credentials "Barveil-Notary" \
#          --apple-id you@example.com \
#          --team-id XXXXXXXXXX \
#          --password "app-specific-password"
#
# Usage:
#   TEAM_ID=XXXXXXXXXX ./scripts/notarize.sh
#   TEAM_ID=XXXXXXXXXX NOTARY_PROFILE=Barveil-Notary IDENTITY="Developer ID Application: Name (XXXX)" ./scripts/notarize.sh
#
# Environment:
#   TEAM_ID        10-char Apple Developer Team ID (required)
#   NOTARY_PROFILE keychain notarytool profile name (default: Barveil-Notary)
#   IDENTITY        codesign identity; auto-detected if omitted
#   VERSION        marketing version used in artifact names (default: 1.0.0)

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:?Set TEAM_ID (see developer.apple.com/account > Membership)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-Barveil-Notary}"
VERSION="${VERSION:-1.0.0}"
CONFIGURATION="Release"
DERIVED_DATA="${BARVEIL_DERIVED_DATA:-${TMPDIR:-/tmp}/barveil-dist}"
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Barveil.app"

echo "==> Building $CONFIGURATION (unsigned)"
xcodebuild \
  -project Barveil.xcodeproj \
  -scheme Barveil \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate found in keychain." >&2
  echo "Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
fi
echo "==> Signing with $IDENTITY"

xattr -cr "$APP"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$IDENTITY" \
  --entitlements Config/Barveil.entitlements \
  "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> Notarizing .app"
ZIP="$DERIVED_DATA/Barveil-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling .app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP" || {
  echo "error: Gatekeeper did not accept the app." >&2
  exit 1
}

echo "==> Packaging DMG"
STAGE="$DERIVED_DATA/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DERIVED_DATA/Barveil-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Barveil $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "SUCCESS:"
echo "  $APP"
echo "  $ZIP"
echo "  $DMG"
echo
echo "Distribute the DMG from your website or GitHub Releases."
