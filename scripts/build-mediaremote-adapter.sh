#!/bin/zsh
# Compile the vendored MediaRemoteAdapter.framework (BSD-3, see
# Vendor/mediaremote-adapter/LICENSE). The perl shim in bin/ is what actually
# talks to MediaRemote; this framework is loaded by that Apple-signed perl
# process, which is the only reliable way for a direct-distribution app to
# observe Now Playing on modern macOS.
#
# Usage: scripts/build-mediaremote-adapter.sh [output-framework-path]

set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="Vendor/mediaremote-adapter"
FRAMEWORK_NAME="MediaRemoteAdapter"
OUT="${1:-${TMPDIR:-/tmp}/barveil-media-remote-adapter/${FRAMEWORK_NAME}.framework}"
MIN_MACOS="14.4"

SOURCES=(
  "$VENDOR"/src/adapter/*.m
  "$VENDOR"/src/private/*.m
  "$VENDOR"/src/utility/*.m
)

# test.m is a standalone test client, not part of the framework.
SOURCES=("${(@)SOURCES:#*test.m}")

mkdir -p "$OUT/Versions/A/Resources" "$OUT/Versions/A/Headers"

clang \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min="$MIN_MACOS" \
  -fobjc-arc -fvisibility=default \
  -dynamiclib \
  -framework Foundation -framework AppKit \
  -framework UniformTypeIdentifiers \
  -I"$VENDOR/include" -I"$VENDOR/src" \
  -install_name "@rpath/$FRAMEWORK_NAME.framework/Versions/A/$FRAMEWORK_NAME" \
  -o "$OUT/Versions/A/$FRAMEWORK_NAME" \
  "${SOURCES[@]}"

cp "$VENDOR/include/$FRAMEWORK_NAME.h" "$OUT/Versions/A/Headers/"
cat > "$OUT/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key><string>app.barveil.MediaRemoteAdapter</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
(cd "$OUT/Versions" && ln -sfn A Current)
(cd "$OUT" \
  && ln -sfn "Versions/Current/$FRAMEWORK_NAME" "$FRAMEWORK_NAME" \
  && ln -sfn "Versions/Current/Resources" "Resources" \
  && ln -sfn "Versions/Current/Headers" "Headers")

codesign --force --sign - "$OUT"
echo "built: $OUT"
