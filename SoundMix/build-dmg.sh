#!/bin/bash
# Build a compressed, drag-to-Applications macOS installer using system tools.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "") bash ./build.sh ;;
    --skip-build) ;;
    *) echo "Usage: $0 [--skip-build]" >&2; exit 2 ;;
esac

APP="build/SoundMix.app"
PLIST="$APP/Contents/Info.plist"
[[ -x "$APP/Contents/MacOS/SoundMix" ]] || { echo "Build SoundMix.app first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid app version metadata." >&2; exit 1;
}
# A skipped build must package what the sources say, not what happens to be in
# build/: the app's stamped version has to match the VERSION and BUILD_NUMBER
# files, otherwise the DMG would ship stale code under a new identity.
FILE_VERSION=$(cat VERSION)
FILE_BUILD=$(cat BUILD_NUMBER 2>/dev/null || echo 0)
[[ "$VERSION" == "$FILE_VERSION" ]] || {
    echo "App version $VERSION does not match VERSION file $FILE_VERSION. Rebuild, or update VERSION." >&2
    exit 1
}
[[ "$BUILD" == "$FILE_BUILD" ]] || {
    echo "App build $BUILD does not match BUILD_NUMBER file $FILE_BUILD. Rebuild before packaging." >&2
    exit 1
}
# Without a real Sparkle public key the installed app could never verify an
# update, so it would be stuck on this build. Catch that before packaging.
ED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)
[[ -n "$ED_KEY" && "$ED_KEY" != "SPARKLE_PUBLIC_KEY_NOT_SET" ]] || {
    echo "SUPublicEDKey is missing or SPARKLE_PUBLIC_KEY_NOT_SET in $PLIST." >&2
    echo "Run Vendor/Sparkle/bin/generate_keys once, put the public key it prints in" >&2
    echo "Resources/Info.plist under SUPublicEDKey, then rebuild." >&2
    exit 1
}
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/SoundMix-$VERSION-build-$BUILD.dmg"
[[ ! -e "$DMG" ]] || { echo "Already exists: $DMG. Use a new build number." >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/soundmix-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/payload"
ditto "$APP" "$STAGING/payload/SoundMix.app"
ln -s /Applications "$STAGING/payload/Applications"
cat > "$STAGING/payload/Install.txt" <<TXT
SoundMix $VERSION (build $BUILD)

1. Drag SoundMix.app to the Applications folder.
2. Eject this disk image.
3. Open SoundMix from Applications.

Requires macOS 14 or later. This build is for $(uname -m).
After this install, SoundMix updates itself: it offers new versions, or choose
File > Check for Updates…
TXT

echo "==> Creating $DMG"
hdiutil create -volname "SoundMix $VERSION" -srcfolder "$STAGING/payload" \
    -format UDZO -fs HFS+ "$STAGING/installer.dmg"
hdiutil verify "$STAGING/installer.dmg"
mv "$STAGING/installer.dmg" "$DMG"
echo "==> Installer ready: $PWD/$DMG"

TAG="v$VERSION-build-$BUILD"

echo "==> Creating local git tag $TAG"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists locally. Keeping it."
else
    git tag -a "$TAG" -m "SoundMix $VERSION build $BUILD"
fi

if [ "${UPLOAD_RELEASE:-0}" = "1" ]; then
    echo "==> Uploading $DMG to GitHub release $TAG"
    RELEASE_NOTES="${RELEASE_NOTES:-SoundMix $VERSION build $BUILD for macOS 14 or later.}"

    # We must push the tag before creating the release so GitHub associates it with the right commit
    git push origin "$TAG" || true

    # The repo was renamed SoundAPP → SoundMix; the old slug still redirects,
    # but publishing under the canonical name keeps it the source of truth.
    # Always a draft: the app reads releases/latest/download/appcast.xml, and
    # this path uploads no appcast.xml. Published as "latest" it would 404 and
    # break every installed copy's update check. Add appcast.xml (see
    # make-appcast.sh) before publishing the draft.
    gh release create "$TAG" "$DMG" --draft \
        --repo oleggohman/SoundMix \
        --title "SoundMix $VERSION build $BUILD" \
        --notes "$RELEASE_NOTES"
else
    echo "==> Skipping GitHub upload (set UPLOAD_RELEASE=1 to create a draft release $TAG)"
fi
