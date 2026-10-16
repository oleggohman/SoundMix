#!/bin/bash
# Convert the artwork into all standard macOS icon resolutions.
set -euo pipefail
cd "$(dirname "$0")"
SOURCE="Resources/AppIcon.png"
[[ -f "$SOURCE" ]] || { echo "Missing icon artwork: $SOURCE" >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/soundmix-icon.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ICONSET="$STAGING/AppIcon.iconset"
mkdir "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
