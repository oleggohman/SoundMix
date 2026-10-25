#!/bin/bash
# Builds SoundMix.app. No Xcode project, no package manager, no network.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SoundMix"
BINARY="SoundMix"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"
# Sparkle is committed under Vendor/ (see Vendor/Sparkle/VERSION), so the
# build stays offline.
SPARKLE_DIR="Vendor/Sparkle"

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$MODCACHE"

# The app links Sparkle from Contents/Frameworks, hence the rpath.
swiftc -O -swift-version 5 \
    -module-cache-path "$MODCACHE" \
    -framework AppKit -framework CoreAudio -framework AudioToolbox \
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
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
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Hardened runtime enforces library validation: the app may only load
# Sparkle when both carry the same Team ID. Ad-hoc signatures carry none, so
# the runtime is only on when a real identity signs everything. Local builds
# skip the secure timestamp to stay offline, so this output is NOT
# notarizable: a release must be re-signed with a secure timestamp
# (`codesign --timestamp`), then notarized and stapled, before make-appcast.sh.
# The runtime also strictly enforces microphone access, so the entitlement
# is required.
SIGN_ID="-"
SIGN_FLAGS=()
if [[ -n "${AppleIDENTITY:-}" ]] \
    && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$AppleIDENTITY"; then
    SIGN_ID="$AppleIDENTITY"
    SIGN_FLAGS=(--options runtime --timestamp=none)
    echo "==> Signing (\$AppleIDENTITY, hardened runtime)"
else
    echo "==> Signing (ad-hoc, no hardened runtime: \$AppleIDENTITY not set or not in the keychain;"
    echo "    ad-hoc pieces have no Team ID, so library validation would refuse Sparkle)"
fi
# Signing goes inside-out instead of --deep: Sparkle's helpers first, then
# the framework that holds them, then the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign() {
    codesign --force --sign "$SIGN_ID" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$@"
}
sign_bundle() {
    sign "$SPARKLE_FW/Versions/B/Autoupdate" || return 1
    sign "$SPARKLE_FW/Versions/B/Updater.app" || return 1
    # No XPC services ship today (removed in Vendor/); signed if they return.
    local xpc
    for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
        [[ -e "$xpc" ]] || continue
        sign "$xpc" || return 1
    done
    sign "$SPARKLE_FW" || return 1
    sign --entitlements SoundMix.entitlements "$APP"
}
# With a real identity a signing failure (locked keychain, expired cert) would
# leave a half-signed app, so it is fatal; ad-hoc signing stays best effort.
if ! sign_bundle; then
    if [[ "$SIGN_ID" != "-" ]]; then
        echo "error: code signing with \$AppleIDENTITY failed; see the codesign error above." >&2
        exit 1
    fi
    echo "    (code signing failed; see the codesign error above)"
fi
if ! codesign --verify --deep --strict "$APP"; then
    if [[ "$SIGN_ID" != "-" ]]; then
        echo "error: signature verification of $APP failed." >&2
        exit 1
    fi
    echo "    (signature verification failed; ad-hoc build)"
fi

echo "==> Built $APP — version $VERSION (build $BUILD_NUMBER)"
du -sh "$APP" | sed 's/^/    /'
