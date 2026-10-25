#!/bin/bash
# Writes dist/appcast.xml, the Sparkle feed for one release DMG.
#
# Usage: ./make-appcast.sh <path/to/stapled.dmg> <release-notes.md>
#
# Run it only after the DMG is Developer ID signed, notarized AND stapled:
# stapling rewrites the DMG, so a signature taken earlier would not match the
# published file and every installed copy would reject the update.
#
# The EdDSA private key stays in the login Keychain, where generate_keys put
# it; sign_update reads it from there. This script never takes, reads or
# prints the private key.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 <path/to/stapled.dmg> <release-notes.md>" >&2; exit 2; }
[[ -f "$1" ]] || { echo "No such DMG: $1" >&2; exit 1; }
[[ -f "$2" ]] || { echo "No such release notes file: $2" >&2; exit 1; }
# Resolve the arguments before changing directory, so relative paths work.
DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NOTES="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
cd "$(dirname "$0")"

SIGN_UPDATE="Vendor/Sparkle/bin/sign_update"
GENERATE_KEYS="Vendor/Sparkle/bin/generate_keys"
[[ -x "$SIGN_UPDATE" ]] || { echo "Missing $SIGN_UPDATE. Vendor Sparkle first." >&2; exit 1; }
[[ -x "$GENERATE_KEYS" ]] || { echo "Missing $GENERATE_KEYS. Vendor Sparkle first." >&2; exit 1; }

FEED="dist/appcast.xml"
MIN_SYSTEM="14.0"
REPO="oleggohman/SoundMix"

# The feed's identity comes from the version files, and the DMG name and the
# app inside it must agree; otherwise the feed would advertise one build and
# ship another.
VERSION=$(cat VERSION)
BUILD=$(cat BUILD_NUMBER)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid VERSION ($VERSION) or BUILD_NUMBER ($BUILD)." >&2; exit 1;
}
DMG_NAME="SoundMix-$VERSION-build-$BUILD.dmg"
[[ "$(basename "$DMG")" == "$DMG_NAME" ]] || {
    echo "DMG is named $(basename "$DMG"), but VERSION/BUILD_NUMBER say $DMG_NAME." >&2; exit 1;
}

# A DMG without a stapled ticket is not the final file; refuse it.
xcrun stapler validate -q "$DMG" >/dev/null 2>&1 || {
    echo "$DMG has no valid stapled notarization ticket. Notarize and staple it first." >&2; exit 1;
}

# Read the app's own stamped version and Sparkle key from inside the image.
# A read-only mount does not change the DMG's bytes.
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/soundmix-appcast.XXXXXX")
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; rm -f "${TMP_FEED:-}"' EXIT
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
PLIST="$MOUNT/SoundMix.app/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "No SoundMix.app in $DMG." >&2; exit 1; }
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)
hdiutil detach -quiet "$MOUNT"
[[ "$APP_VERSION" == "$VERSION" && "$APP_BUILD" == "$BUILD" ]] || {
    echo "App in DMG is $APP_VERSION build $APP_BUILD, expected $VERSION build $BUILD." >&2; exit 1;
}
[[ -n "$APP_KEY" && "$APP_KEY" != "SPARKLE_PUBLIC_KEY_NOT_SET" ]] || {
    echo "App in DMG has no Sparkle public key (SUPublicEDKey); it could never verify a later update." >&2; exit 1;
}

# The Keychain key signs the feed, the app's SUPublicEDKey verifies it. If they
# differ, every installed copy would reject the update. `generate_keys -p` only
# prints the existing public key; it creates nothing.
KEYCHAIN_KEY=$("$GENERATE_KEYS" -p) || {
    echo "Could not read the Sparkle public key from the Keychain." >&2; exit 1;
}
[[ "$KEYCHAIN_KEY" == "$APP_KEY" ]] || {
    echo "SUPublicEDKey in the DMG's app ($APP_KEY) differs from the Keychain signing key ($KEYCHAIN_KEY); installed copies would reject this update." >&2; exit 1;
}

# One feed per release. Regenerating for the same build is fine; replacing a
# feed for another build would hide a release that was never uploaded.
if [[ -f "$FEED" ]]; then
    OLD_BUILD=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$FEED" | head -n 1)
    [[ "$OLD_BUILD" == "$BUILD" ]] || {
        echo "$FEED is for build ${OLD_BUILD:-unknown}, not $BUILD. Move it away first." >&2; exit 1;
    }
fi

echo "==> Signing $DMG with the Sparkle key from the login Keychain"
# sign_update prints: sparkle:edSignature="..." length="..."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG")
SIGNATURE=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
SIGNED_LENGTH=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')
LENGTH=$(stat -f %z "$DMG")
[[ -n "$SIGNATURE" ]] || { echo "sign_update printed no signature." >&2; exit 1; }
[[ "$SIGNED_LENGTH" == "$LENGTH" ]] || {
    echo "sign_update length $SIGNED_LENGTH does not match file size $LENGTH." >&2; exit 1;
}

TAG="v$VERSION-build-$BUILD"
URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

# Minimal Markdown to HTML for Sparkle's notes view: headings, bullet lists and
# paragraphs; everything else stays plain text. Escaping < > & also keeps "]]>"
# out of the CDATA section.
notes_html() {
    awk '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
        function close_list() { if (in_list) { print "</ul>"; in_list = 0 } }
        function close_para() { if (para != "") { print "<p>" para "</p>"; para = "" } }
        /^[[:space:]]*$/ { close_para(); close_list(); next }
        /^#+[[:space:]]/ { close_para(); close_list(); sub(/^#+[[:space:]]+/, ""); print "<h3>" esc($0) "</h3>"; next }
        /^[[:space:]]*[-*][[:space:]]/ {
            close_para()
            if (!in_list) { print "<ul>"; in_list = 1 }
            sub(/^[[:space:]]*[-*][[:space:]]+/, ""); print "<li>" esc($0) "</li>"; next
        }
        { close_list(); para = (para == "" ? esc($0) : para " " esc($0)) }
        END { close_para(); close_list() }
    ' "$NOTES"
}

mkdir -p dist
TMP_FEED=$(mktemp "${TMPDIR:-/tmp}/soundmix-appcast-xml.XXXXXX")
{
    cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SoundMix</title>
    <link>https://github.com/$REPO</link>
    <description>SoundMix updates</description>
    <language>en</language>
    <item>
      <title>SoundMix $VERSION build $BUILD</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[
XML
    notes_html
    cat <<XML
]]></description>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
} > "$TMP_FEED"
xmllint --noout "$TMP_FEED"

echo "==> Verifying the feed's signature against the DMG"
# Read the signature back from the written feed, so what is checked is what
# will be published; only a verified feed replaces dist/appcast.xml.
FEED_SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$TMP_FEED")
"$SIGN_UPDATE" --verify "$DMG" "$FEED_SIGNATURE" || {
    rm -f "$TMP_FEED"; echo "Signature check failed; $FEED not written." >&2; exit 1;
}
mv "$TMP_FEED" "$FEED"

echo "==> Wrote $PWD/$FEED for $TAG"
echo "    Upload it with the DMG: gh release create $TAG $DMG $PWD/$FEED --repo $REPO ..."
