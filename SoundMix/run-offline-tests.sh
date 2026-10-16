#!/bin/bash
# Renders real files through the full chain and checks the results. No hardware.
set -euo pipefail
cd "$(dirname "$0")"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"
mkdir -p build "$MODCACHE"
swiftc -O -swift-version 5 -module-cache-path "$MODCACHE" \
    Sources/SoundMixCore/*.swift Sources/SoundMixEngine/*.swift Tests/Offline/main.swift \
    -o build/offlinetests
exec ./build/offlinetests
