#!/bin/zsh
# Local build: fixed-identity signed when available, unsandboxed for the
# direct-distribution model, so the menu-bar/media detection works with
# stable macOS permissions.
#
#   scripts/build.sh            # Release
#   scripts/build.sh Debug
#
# The build always bundles the vendored MediaRemoteAdapter framework and its
# perl shim, which is how the app observes Now Playing without entitlements.

set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIGURATION="${1:-Release}"

# Derived data lives outside the project on purpose: folders that are synced
# or managed by a file provider stamp extended attributes on every product,
# and codesign refuses to sign a bundle that carries them.
DERIVED_DATA="${BARVEIL_DERIVED_DATA:-${TMPDIR:-/tmp}/barveil-derived-data}"

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Barveil.app"
# Ad-hoc signing is the default: it needs no keychain identity, no login
# password and no Apple Development key. Set both variables explicitly when a
# Developer ID/Apple Development signature is actually wanted.
SIGNING_IDENTITY="${BARVEIL_CODESIGN_IDENTITY:-}"
SIGNING_TEAM="${BARVEIL_DEVELOPMENT_TEAM:-}"
MARKETING_VERSION="${BARVEIL_MARKETING_VERSION:-}"
version_settings=()
if [[ -n "$MARKETING_VERSION" ]]; then
    version_settings+=(MARKETING_VERSION="$MARKETING_VERSION")
fi

if [[ -n "$SIGNING_IDENTITY" && -n "$SIGNING_TEAM" ]]; then
    # Let Xcode sign so development entitlements stay in sync. The stable
    # identity keeps the Accessibility grant across rebuilds; ad-hoc signing
    # changes the CDHash and invalidates it.
    xcodebuild \
      -project Barveil.xcodeproj \
      -scheme Barveil \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
      DEVELOPMENT_TEAM="$SIGNING_TEAM" \
      PROVISIONING_PROFILE_SPECIFIER='' \
      "${version_settings[@]}" \
      build
else
    echo "using ad-hoc signing (no keychain prompt)." >&2
    echo "warning: macOS Accessibility permission will need to be granted again after each rebuild." >&2

    xcodebuild \
      -project Barveil.xcodeproj \
      -scheme Barveil \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      "${version_settings[@]}" \
      build

    # `xattr -cr` has to run before an ad-hoc signature because folders that
    # live on a synced or file-provider volume stamp extended attributes on
    # every product, and codesign refuses to sign such a bundle.
    xattr -cr "$APP"

    # Xcode's Debug configuration puts the real code in a nested dylib. It has
    # to carry the same identity as the stub executable.
    for nested in \
        "$APP/Contents/MacOS/Barveil.debug.dylib" \
        "$APP/Contents/MacOS/__preview.dylib"
    do
        if [[ -f "$nested" ]]; then
            codesign --force --sign - "$nested"
        fi
    done

    codesign \
      --force \
      --sign - \
      --entitlements Config/Barveil.entitlements \
      "$APP"
fi

# ---------------------------------------------------------------------------
# MediaRemote adapter
# ---------------------------------------------------------------------------
# The adapter process is /usr/bin/perl, which is on Apple's MediaRemote
# allowlist. Bundling the vendored framework + perl shim is what makes the
# Chromium/Now Playing pause signal reliable without any private entitlement.
ADAPTER_DIR="${TMPDIR:-/tmp}/barveil-media-remote-adapter"
scripts/build-mediaremote-adapter.sh "$ADAPTER_DIR/MediaRemoteAdapter.framework" >/dev/null
mkdir -p "$APP/Contents/Resources"
# Older builds copied a third-party notice here; remove it so incremental
# builds and packaged apps cannot retain a stale resource.
rm -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [[ -e "$APP/Contents/Resources/MediaRemoteAdapter.framework" ]]; then
    rm -rf "$APP/Contents/Resources/MediaRemoteAdapter.framework"
fi
ditto "$ADAPTER_DIR/MediaRemoteAdapter.framework" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
ditto Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/mediaremote-adapter.pl"
ditto Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
chmod +x "$APP/Contents/Resources/mediaremote-adapter.pl"

# Ship the project license inside the bundle.
ditto LICENSE "$APP/Contents/Resources/LICENSE.txt"

if [[ -n "$SIGNING_IDENTITY" && -n "$SIGNING_TEAM" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
      "$APP/Contents/Resources/MediaRemoteAdapter.framework"
    codesign --force --options runtime \
      --entitlements Config/Barveil.entitlements \
      --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - \
      "$APP/Contents/Resources/MediaRemoteAdapter.framework"
    codesign --force --sign - \
      --entitlements Config/Barveil.entitlements "$APP"
fi

echo
echo "built: $APP"
if [[ -n "$SIGNING_IDENTITY" && -n "$SIGNING_TEAM" ]]; then
    echo "signed with: $SIGNING_IDENTITY (team $SIGNING_TEAM)"
else
    echo "signed with: ad-hoc"
fi
codesign -d --entitlements - "$APP" 2>&1 | tail -n +2
