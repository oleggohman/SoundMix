#!/bin/bash
# Runs the DSP verification suite. No audio hardware required.
set -euo pipefail
cd "$(dirname "$0")"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"
mkdir -p build "$MODCACHE"
swiftc -O -swift-version 5 -module-cache-path "$MODCACHE" \
    Sources/SoundMixCore/*.swift Tests/main.swift -o build/dsptests
exec ./build/dsptests
