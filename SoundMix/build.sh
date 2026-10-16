#!/bin/bash
# Builds SoundMix.app. No Xcode project, no package manager, no network.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SoundMix"
BINARY="SoundMix"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"

VERSION=$(cat VERSION)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid VERSION: expected major.minor.patch" >&2
    exit 1
fi
# The build counter lives in the tracked BUILD_NUMBER file, not in the built
# app's plist: a binary in git should not be the source of truth for versioning.
# CI can still supply a number explicitly.
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    if [[ ! -f BUILD_NUMBER ]]; then
        echo "Missing BUILD_NUMBER file; create it with the last used build number." >&2
        exit 1
    fi
    PREVIOUS_BUILD=$(cat BUILD_NUMBER)
    if [[ ! "$PREVIOUS_BUILD" =~ ^[0-9]{1,9}$ ]]; then
        echo "Invalid BUILD_NUMBER file contents; expected a number up to 9 digits." >&2
        exit 1
    fi
    BUILD_NUMBER=$((10#$PREVIOUS_BUILD + 1))
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "Invalid BUILD_NUMBER: expected a positive integer (up to 9 digits)." >&2
    exit 1
fi
printf '%s\n' "$BUILD_NUMBER" > BUILD_NUMBER

echo "==> Preparing app icon"
bash ./build-icon.sh

echo "==> Compiling SoundMix $VERSION (build $BUILD_NUMBER)"
# Start from a clean bundle: resource copies below merge, so files removed
# from Resources/ would otherwise survive from the previous build.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODCACHE"

swiftc -O -swift-version 5 \
    -module-cache-path "$MODCACHE" \
    -framework AppKit -framework CoreAudio -framework AudioToolbox \
    Sources/SoundMixCore/*.swift \
    Sources/SoundMixEngine/*.swift \
    Sources/SoundMixApp/*.swift \
    -o "$APP/Contents/MacOS/$BINARY"

echo "==> Building test tools"
swiftc -O -swift-version 5 -module-cache-path "$MODCACHE" \
    Tools/BedGenerator/main.swift -o "$BUILD_DIR/bedgen"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP/Contents/Info.plist"
# The reference-target list follows the drop folder of curve files (default
# ../Targets, override with SOUND_TARGETS_DIR). A missing folder keeps the
# existing targets, so the build works on any machine.
echo "==> Syncing reference targets"
python3 Tools/sync_targets.py

ditto Resources/Targets "$APP/Contents/Resources/Targets"
cp -R Resources/SoundMix.help "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc, hardened runtime)"
# --options runtime is required for notarization later.
# It strictly enforces microphone access, so the entitlement is required.
codesign --force --deep --sign - --options runtime --entitlements SoundMix.entitlements "$APP" 2>/dev/null \
    || codesign --force --deep --sign - --entitlements SoundMix.entitlements "$APP" 2>/dev/null \
    || echo "    (ad-hoc signing unavailable; the app still runs locally)"

echo "==> Built $APP — version $VERSION (build $BUILD_NUMBER)"
du -sh "$APP" | sed 's/^/    /'
